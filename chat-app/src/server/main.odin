
package server

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:thread"
import "core:time"
import "core:sync"

import "core:encoding/json"
import "core:strings"
import "core:bufio"
import "core:crypto/sha256"
import "core:encoding/hex"
// Using the refined hypothetical SQLite API
import sqlite "refhyp:sqlite"

import "../shared/types"
import "../shared/protocol"


// Database global
db: ^sqlite.DB // Type changed to ^sqlite.DB as per refined hypothetical API

// ClientSession stores information about a connected client
ClientSession :: struct {
    id:          u64,
    conn:        net.Conn,

    user:        ^types.User,
    remote_addr: net.Address,
    current_channel_name: string, // Name of the channel the user is currently in
}

// ChannelData stores information and state for a single chat channel
ChannelData :: struct {
    id:       u64, // Database ID of the channel
    name:     string,
    users:    map[u64]^ClientSession, // Keyed by session.id
    messages: [dynamic]types.Message, // Message history

}

// Global state for managing clients
connected_clients := make(map[u64]^ClientSession)
clients_mutex     : sync.Mutex
next_client_id    : u64 = 1


// Global state for managing chat channels
chat_channels   := make(map[string]^ChannelData)
channels_mutex  : sync.Mutex


// WARNING: THIS IS A PLACEHOLDER AND NOT SECURE FOR PRODUCTION.
// A proper password hashing library (e.g., bcrypt, scrypt, or argon2) should be used.
FIXED_SALT :: "a_very_salty_salt_string_for_chat_app" // TODO: Replace with secure handling

hash_password :: proc(password: string) -> (hashed_password_hex: string, err: Error) {
    log.warn("Using placeholder SHA256 password hashing. NOT FOR PRODUCTION.")

    salted_password := FIXED_SALT + password

    hasher := sha256.new()
    sha256.write(&hasher, transmute([]u8)salted_password)
    hash_bytes := sha256.sum(&hasher)

    // Convert hash to hex string
    hashed_password_hex = hex.encode_to_string(hash_bytes[:])
    return hashed_password_hex, nil
}

verify_password :: proc(password: string, stored_hash_hex: string) -> bool {
    log.warn("Verifying with placeholder SHA256 password hashing. NOT FOR PRODUCTION.")

    new_hash, err := hash_password(password)
    if err != nil {
        log.errorf("Error hashing password during verification: %v", err)
        return false
    }
    return new_hash == stored_hash_hex
}

// Helper to send a JSON message with a newline
send_json_message :: proc(conn: net.Conn, session_id: u64, message: any) -> (err: net.Error) {
    response_bytes, marshal_err := json.marshal(message)
    if marshal_err != nil {
        log.errorf("Client %d: Failed to marshal message type %T: %v", session_id, message, marshal_err)

        return net.EINVAL
    }


    newline_char := []u8{'\n'}
    response_final := make([]u8, len(response_bytes) + len(newline_char))
    copy(response_final, response_bytes)
    copy(response_final[len(response_bytes):], newline_char)

    _, write_err := net.write_all(conn, response_final)
    if write_err != nil {

        // Log error, but don't make it fatal for the helper itself, caller can decide.
        // log.errorf("Client %d: Error sending message type %T: %v", session_id, message, write_err)

        return write_err
    }
    log.debugf("Client %d: Sent message type %T successfully.", session_id, message)
    return nil
}

// handle_client is responsible for managing a single client's lifecycle using JSON messages.
handle_client :: proc(conn: net.Conn) {
    remote_addr := net.remote_address(conn)
    session_id: u64

    session: ^ClientSession

    sync.mutex_lock(&clients_mutex)
    session_id = next_client_id
    next_client_id += 1
    session = new(ClientSession)
    session^ = ClientSession{
        id          = session_id,
        conn        = conn,
        user        = nil,
        remote_addr = remote_addr,
        current_channel_name = "",
    }
    connected_clients[session_id] = session
    sync.mutex_unlock(&clients_mutex)
    log.infof("Client %v connected with Session ID %d.", remote_addr, session_id)

    defer {
        if session.current_channel_name != "" {
            sync.mutex_lock(&channels_mutex)
            if old_channel, exists := chat_channels[session.current_channel_name]; exists {
                log.infof("Client %d (%s) is leaving channel '%s'. Removing from in-memory list.",
                          session.id, session.user.username if session.user != nil else "UnknownUser", session.current_channel_name)
                delete(old_channel.users, session.id) // Remove before broadcasting to avoid self-notification

                if session.user != nil { // Only broadcast if user was properly logged in
                    leave_msg := protocol.create_s2c_user_left_channel_message(
                        session.user.id,
                        session.user.username,
                        session.current_channel_name,
                    )
                    // Broadcast to remaining users in the channel
                    for _, user_in_channel := range old_channel.users {
                        if user_in_channel != nil && user_in_channel.conn != nil {
                            log.debugf("Notifying user %d (%s) in channel '%s' that user %d (%s) left.",
                                       user_in_channel.id, user_in_channel.user.username,
                                       session.current_channel_name,
                                       session.user.id, session.user.username)
                            send_json_message(user_in_channel.conn, user_in_channel.id, leave_msg)
                        }
                    }
                    log.infof("Broadcasted user left notification for %s from channel '%s'.", session.user.username, session.current_channel_name)
                } else {
                    log.warnf("User (session ID %d, not fully logged in) left channel '%s', no broadcast sent.", session.id, session.current_channel_name)
                }
            }
            sync.mutex_unlock(&channels_mutex)
        }

        net.close(conn)
        sync.mutex_lock(&clients_mutex)
        delete(connected_clients, session_id)
        sync.mutex_unlock(&clients_mutex)
        log.infof("Client %v (ID %d) disconnected. Active clients: %d", remote_addr, session_id, len(connected_clients))
    }


    reader := bufio.make_reader(conn, bufio.DEFAULT_BUFFER_SIZE)
    for {
        line_bytes, err := bufio.read_line_bytes(reader)
        if err != nil {
            if err == net.EOF { log.infof("Client %d (%v): Connection closed (EOF).", session.id, remote_addr) }
            else if err == net.EAGAIN { log.warnf("Client %d (%v): Read EAGAIN.", session.id, remote_addr); thread.sleep(50*time.Millisecond); continue }
            else { log.errorf("Read error client %d (%v): %v", session.id, remote_addr, err) }
            break
        }
        if len(line_bytes) == 0 { log.debugf("Client %d: Empty line.", session.id); continue }
        log.debugf("Client %d: Raw line (len %d): %s", session.id, len(line_bytes), string(line_bytes))

        if session.user != nil { // Client is LOGGED IN
            var base_msg protocol.BaseMessage
            json_err_base := json.unmarshal(line_bytes, &base_msg)
            if json_err_base != nil {
                log.errorf("Client %d (%s): Failed to unmarshal BaseMessage JSON: %v. Raw: %s", session.id, session.user.username, json_err_base, string(line_bytes))
                err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "Invalid message format.", original_request_type = base_msg.type }
                send_json_message(session.conn, session.id, err_resp)
                continue
            }
            log.debugf("Client %d (%s): Received message type %v", session.id, session.user.username, base_msg.type)

            switch base_msg.type {
            case protocol.MessageType.C2S_JOIN_CHANNEL:
                // ... (previous C2S_JOIN_CHANNEL logic remains here) ...
                var join_msg protocol.C2S_Join_Channel_Message
                json_err := json.unmarshal(line_bytes, &join_msg)
                if json_err != nil {
                    log.errorf("Client %d: Failed to unmarshal C2S_JOIN_CHANNEL: %v. Raw: %s", session.id, json_err, string(line_bytes))
                    err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "Invalid join channel message format.", original_request_type = .C2S_JOIN_CHANNEL }
                    send_json_message(session.conn, session.id, err_resp)
                    continue
                }
                log.infof("Client %d (%s): Joining channel '%s'", session.id, session.user.username, join_msg.channel_name)
                sync.mutex_lock(&channels_mutex)
                target_channel, exists := chat_channels[join_msg.channel_name]
                if exists {
                    if session.current_channel_name != "" && session.current_channel_name != join_msg.channel_name {
                        if old_channel, old_exists := chat_channels[session.current_channel_name]; old_exists {
                            delete(old_channel.users, session.id)
                            log.infof("Client %d (%s) removed from old channel '%s'.", session.id, session.user.username, session.current_channel_name)
                        }
                    }
                    if session.current_channel_name != join_msg.channel_name {
                         target_channel.users[session.id] = session
                         session.current_channel_name = join_msg.channel_name
                    }
                    sync.mutex_unlock(&channels_mutex) // Unlock before further DB ops / message sending
                    log.infof("Client %d (%s) joined channel '%s'. Users: %d", session.id, session.user.username, join_msg.channel_name, len(target_channel.users))

                    // Send S2C_User_Joined_Channel_Message first
                    join_response := protocol.S2C_User_Joined_Channel_Message{ base = protocol.BaseMessage{type = .S2C_USER_JOINED_CHANNEL}, channel_name = join_msg.channel_name, user = session.user^, }
                    send_json_message(session.conn, session.id, join_response)

                    // Then, load and send message history
                    channel_db_id := target_channel.id
                    history_rows, err_hist := db.query(
                        "SELECT message_id, user_db_id, content, image_path, created_at FROM messages WHERE channel_db_id = ? ORDER BY created_at ASC LIMIT 50",
                        channel_db_id,
                    )
                    if err_hist != nil {
                        log.errorf("Client %d (%s): Failed to load message history for channel '%s' (DB ID %d): %v", session.id, session.user.username, target_channel.name, channel_db_id, err_hist)
                        // Don't disconnect, but client won't get history. Maybe send an error specific to history? For now, just log.
                    } else {
                        history_messages := make([dynamic]types.Message)
                        for row_map in history_rows {
                            // Defensive type assertions and checks
                            msg_id_any, ok_msg_id := row_map["message_id"]
                            user_db_id_any, ok_user_db_id := row_map["user_db_id"]
                            content_any, ok_content := row_map["content"]
                            created_at_any, ok_created_at := row_map["created_at"]
                            image_path_any, _ := row_map["image_path"] // image_path can be nil/null

                            if !ok_msg_id || !ok_user_db_id || !ok_content || !ok_created_at {
                                log.errorf("Client %d (%s): Malformed message row from DB for channel '%s'. Row: %v", session.id, session.user.username, target_channel.name, row_map)
                                continue
                            }

                            parsed_time, time_err := time.parse_iso8601(created_at_any.(string)) // Assuming string format from DB
                            if time_err != nil {
                                log.errorf("Client %d (%s): Failed to parse timestamp '%s' for message %v in channel '%s': %v", session.id, session.user.username, created_at_any.(string), msg_id_any, target_channel.name, time_err)
                                // Use a default time or skip? For now, use time.Time{}
                                parsed_time = time.Time{}
                            }

                            image_path_str := ""
                            if img_path_val, ok_img_path := image_path_any.(string); ok_img_path { // Check if string and not nil
                                image_path_str = img_path_val
                            }


                            msg := types.Message{
                                id = msg_id_any.(u64), // Assuming direct u64 or i64 that casts
                                author_id = user_db_id_any.(u64),
                                channel_name = target_channel.name,
                                content = content_any.(string),
                                image_path = image_path_str,
                                timestamp = parsed_time,
                                edited = false, // History messages are not marked as edited by default
                            }
                            append(&history_messages, msg)
                        }
                        log.infof("Client %d (%s): Loaded %d messages for history of channel '%s'.", session.id, session.user.username, len(history_messages), target_channel.name)
                        history_msg_payload := protocol.create_s2c_message_history_message(target_channel.name, history_messages)
                        send_json_message(session.conn, session.id, history_msg_payload)
                    }
                } else {
                    // This sync.mutex_unlock was here before, ensure it's correctly placed if the 'else' path is taken.
                    // If the 'if exists' is false, the lock is released here.
                    // If 'if exists' is true, it should be released before this 'else' block.
                    // The refactor above moved the unlock to happen before this else.
                    sync.mutex_unlock(&channels_mutex)
                    log.warnf("Client %d (%s): Tried to join non-existent channel '%s'", session.id, session.user.username, join_msg.channel_name)
                    err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = fmt.tprintf("Channel '%s' not found.", join_msg.channel_name), original_request_type = .C2S_JOIN_CHANNEL }
                    send_json_message(session.conn, session.id, err_resp)
                }

            case protocol.MessageType.C2S_SEND_MESSAGE:
                var send_msg_req protocol.C2S_Send_Message_Message
                json_err := json.unmarshal(line_bytes, &send_msg_req)
                if json_err != nil {
                    log.errorf("Client %d: Failed to unmarshal C2S_SEND_MESSAGE: %v. Raw: %s", session.id, json_err, string(line_bytes))
                    err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "Invalid send message format.", original_request_type = .C2S_SEND_MESSAGE }
                    send_json_message(session.conn, session.id, err_resp)
                    continue
                }

                if session.current_channel_name == "" {
                    log.warnf("Client %d (%s): Tried to send message without being in a channel.", session.id, session.user.username)
                    err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "You are not in a channel. Join a channel first.", original_request_type = .C2S_SEND_MESSAGE }
                    send_json_message(session.conn, session.id, err_resp)
                    continue
                }

                sync.mutex_lock(&channels_mutex)
                current_channel_data, exists := chat_channels[session.current_channel_name]
                if !exists {
                    sync.mutex_unlock(&channels_mutex)
                    log.errorf("CRITICAL: Client %d (%s) in channel '%s' but channel does not exist in global map.", session.id, session.user.username, session.current_channel_name)
                    err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "Internal server error: your current channel was not found.", original_request_type = .C2S_SEND_MESSAGE }
                    send_json_message(session.conn, session.id, err_resp)
                    continue
                }

                // Get channel and user DB IDs
                channel_db_id := current_channel_data.id
                user_db_id := session.user.id // This is already the DB user_id from successful login

                // Insert message into database
                current_timestamp := time.now() // Use a consistent timestamp
                insert_msg_res, err_insert_msg := db.exec(
                    "INSERT INTO messages (channel_db_id, user_db_id, content, image_path, created_at) VALUES (?, ?, ?, ?, ?)",
                    channel_db_id,
                    user_db_id,
                    send_msg_req.content,
                    send_msg_req.image_path, // Assumes empty string if no image, DB schema allows NULL
                    current_timestamp, // Store the timestamp, assuming SQLite handles time.Time correctly or it's formatted
                )

                if err_insert_msg != nil {
                    log.errorf("Client %d (%s): Failed to save message to DB for channel '%s': %v", session.id, session.user.username, current_channel_data.name, err_insert_msg)
                    // Optionally send an S2C_Error_Message to the sender
                    err_resp := protocol.S2C_Error_Message{
                        base = protocol.BaseMessage{type = .S2C_ERROR},
                        error_message = "Failed to send message (server database error).",
                        original_request_type = .C2S_SEND_MESSAGE,
                    }
                    send_json_message(session.conn, session.id, err_resp)
                    sync.mutex_unlock(&channels_mutex) // Unlock before continuing
                    continue
                }

                new_message_db_id := u64(insert_msg_res.last_insert_rowid())

                // Create the types.Message struct for broadcasting and in-memory storage
                new_chat_message := types.Message{
                    id = new_message_db_id, // Use the DB ID
                    author_id = user_db_id, // This is the user's DB ID
                    channel_name = session.current_channel_name,
                    content = send_msg_req.content,
                    image_path = send_msg_req.image_path,
                    timestamp = current_timestamp, // Use the same timestamp
                    edited = false,
                }

                // Store message in this channel's in-memory message list (optional, could be removed if client always relies on history)
                append(&current_channel_data.messages, new_chat_message)
                // TODO: Optional: Limit message history size (e.g., cap at N messages)

                // Prepare broadcast payload
                broadcast_payload := protocol.S2C_New_Message_Message{
                    base = protocol.BaseMessage{type = protocol.MessageType.S2C_NEW_MESSAGE},
                    message = new_chat_message, // This now contains the DB message ID
                }

                log.infof("Broadcasting msg ID %v (DB ID %v) in '%s' to %d users.", new_chat_message.id, new_chat_message.id, current_channel_data.name, len(current_channel_data.users))
                for _, user_in_channel := range current_channel_data.users {
                    if user_in_channel != nil && user_in_channel.conn != nil {
                        log.debugf("Sending msg DB ID %v to user %d (%s)", new_chat_message.id, user_in_channel.id, user_in_channel.user.username)
                        err_send := send_json_message(user_in_channel.conn, user_in_channel.id, broadcast_payload)
                        if err_send != nil {
                             log.errorf("Failed to send message (DB ID %v) to user %d (%s) in channel '%s': %v", new_chat_message.id, user_in_channel.id, user_in_channel.user.username, current_channel_data.name, err_send)
                             // Decide if we should remove this user or mark them as problematic
                        }
                    } else {
                         log.warnf("Skipped broadcast to nil session/conn for session ID %v in channel '%s'", user_in_channel.id if user_in_channel != nil else "unknown", current_channel_data.name)
                    }
                }
                sync.mutex_unlock(&channels_mutex)
                log.infof("Client %d (%s) sent message to '%s': \"%s\"", session.id, session.user.username, session.current_channel_name, send_msg_req.content)

            case protocol.MessageType.C2S_CREATE_CHANNEL:
                var create_channel_msg protocol.C2S_Create_Channel_Message
                json_err := json.unmarshal(line_bytes, &create_channel_msg)
                if json_err != nil {
                    log.errorf("Client %d: Failed to unmarshal C2S_CREATE_CHANNEL: %v. Raw: %s", session.id, json_err, string(line_bytes))
                    err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "Invalid create channel message format.", original_request_type = .C2S_CREATE_CHANNEL }
                    send_json_message(session.conn, session.id, err_resp)
                    continue
                }

                new_channel_name := strings.trim_space(create_channel_msg.name)
                if new_channel_name == "" {
                    log.warnf("Client %d (%s): Attempt to create channel with empty name.", session.id, session.user.username)
                    err_resp := protocol.S2C_Error_Message{base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "Channel name cannot be empty.", original_request_type = .C2S_CREATE_CHANNEL}
                    send_json_message(session.conn, session.id, err_resp)
                    continue
                }

                // Quick check in memory (DB constraint is the ultimate guard)
                sync.mutex_lock(&channels_mutex)
                _, exists_in_map := chat_channels[new_channel_name]
                sync.mutex_unlock(&channels_mutex)
                if exists_in_map {
                    log.warnf("Client %d (%s): Attempt to create already existing (in map) channel '%s'.", session.id, session.user.username, new_channel_name)
                    err_resp := protocol.S2C_Error_Message{base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = fmt.tprintf("Channel '%s' already exists.", new_channel_name), original_request_type = .C2S_CREATE_CHANNEL}
                    send_json_message(session.conn, session.id, err_resp)
                    continue
                }

                // Insert into database
                insert_res, err_insert := db.exec("INSERT INTO channels (channel_name) VALUES (?)", new_channel_name)
                if err_insert != nil {
                    log.errorf("Client %d (%s): Failed to insert new channel '%s' into DB: %v", session.id, session.user.username, new_channel_name, err_insert)
                    error_message := "Server error creating channel."
                    if err_insert == sqlite.ERR_CONSTRAINT { // Unique constraint violated
                        error_message = fmt.tprintf("Channel name '%s' is already taken.", new_channel_name)
                    }
                    err_resp := protocol.S2C_Error_Message{base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = error_message, original_request_type = .C2S_CREATE_CHANNEL}
                    send_json_message(session.conn, session.id, err_resp)
                    continue
                }

                new_channel_id := u64(insert_res.last_insert_rowid())
                log.infof("Client %d (%s): Successfully created channel '%s' (ID: %d).", session.id, session.user.username, new_channel_name, new_channel_id)

                // Add to in-memory map
                new_channel_data_ptr := new(ChannelData)
                new_channel_data_ptr^ = ChannelData{
                    id = new_channel_id,
                    name = new_channel_name,
                    users = make(map[u64]^ClientSession),
                    messages = make([dynamic]types.Message),
                }
                sync.mutex_lock(&channels_mutex)
                chat_channels[new_channel_name] = new_channel_data_ptr
                sync.mutex_unlock(&channels_mutex)

                // Send success response to client
                s2c_resp := protocol.S2C_Channel_Created_Message{
                    base = protocol.BaseMessage{type = .S2C_CHANNEL_CREATED},
                    channel = types.Channel{id = new_channel_id, name = new_channel_name, server_id = 0 /* Assuming global channels for now */},
                }
                send_json_message(session.conn, session.id, s2c_resp)


            case:
                log.warnf("Client %d (%s): Unhandled message type %v", session.id, session.user.username, base_msg.type)
                err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "Unhandled message type.", original_request_type = base_msg.type }
                send_json_message(session.conn, session.id, err_resp)
            }
        } else { // Client is NOT LOGGED IN
            // First, determine the message type
            var base_req protocol.BaseMessage
            json_err_base := json.unmarshal(line_bytes, &base_req)
            if json_err_base != nil {
                log.errorf("Client %d: Failed to unmarshal BaseMessage for non-authed user: %v. Raw: %s", session.id, json_err_base, string(line_bytes))
                // Cannot send S2C_Error_Message if we don't know original_request_type, send generic login failure style.
                failure_resp := protocol.create_s2c_login_failure_message("Invalid message format.")
                send_json_message(session.conn, session.id, failure_resp)
                continue
            }

            switch base_req.type {
            case .C2S_LOGIN:
                var login_msg protocol.C2S_Login_Message
                json_err := json.unmarshal(line_bytes, &login_msg)
                if json_err != nil {
                    log.errorf("Client %d: Failed to unmarshal C2S_LOGIN JSON: %v. Raw: '%s'", session.id, json_err, string(line_bytes))
                    failure_resp := protocol.create_s2c_login_failure_message("Invalid login message format.")
                    send_json_message(session.conn, session.id, failure_resp)
                    continue
                }
                log.infof("Client %d: Processing C2S_LOGIN. Username: '%s'", session.id, login_msg.username)

                // Query using parameterized query as per refined hypothetical API
                // db.query_one(sql: string, ..args: any) -> (map[string]any, sqlite.Error)
                user_row_map, query_err := db.query_one(
                    "SELECT user_id, username, email, hashed_password FROM users WHERE username = ?",
                    login_msg.username,
                )

                if query_err != nil {
                    // Handle specific error for user not found
                    if query_err == sqlite.ERR_NO_ROW { // Hypothetical error constant
                        log.warnf("Client %d: Login attempt for non-existent username '%s'.", session.id, login_msg.username)
                        failure_resp := protocol.create_s2c_login_failure_message("Invalid username or password.")
                        send_json_message(session.conn, session.id, failure_resp)
                        continue
                    } else { // Handle other potential database errors
                        log.errorf("Client %d: Database error during login for username '%s': %v", session.id, login_msg.username, query_err)
                        failure_resp := protocol.create_s2c_login_failure_message("Server error during login.")
                        send_json_message(session.conn, session.id, failure_resp)
                        continue
                    }
                }

                // User found, now verify password
                // Type assertions are needed here based on what `query_one` returns for map values.
                // Assuming it returns appropriate types or well-defined string representations that need conversion.
                // For simplicity, direct type assertion is shown. A robust solution would check `ok` from assertion.
                stored_user_id: u64
                stored_username: string
                stored_hashed_pw: string
                stored_email: string

                // Safely extract and type-assert values from the map
                val_user_id, ok_user_id := user_row_map["user_id"]
                if ok_user_id { stored_user_id = val_user_id.(u64) } else { /* Handle missing key error */ }

                val_username, ok_username := user_row_map["username"]
                if ok_username { stored_username = val_username.(string) } else { /* Handle missing key error */ }

                val_hashed_pw, ok_hashed_pw := user_row_map["hashed_password"]
                if ok_hashed_pw { stored_hashed_pw = val_hashed_pw.(string) } else { /* Handle missing key error */ }

                val_email, ok_email := user_row_map["email"]
                if ok_email { stored_email = val_email.(string) } else { /* Handle missing key error */ }

                // Basic check if all required fields were present, otherwise log error and fail
                if !ok_user_id || !ok_username || !ok_hashed_pw || !ok_email {
                    log.errorf("Client %d: Missing fields in user record for username '%s'.", session.id, login_msg.username)
                    failure_resp := protocol.create_s2c_login_failure_message("Server error: Incomplete user data.")
                    send_json_message(session.conn, session.id, failure_resp)
                    continue
                }


                if verify_password(login_msg.password, stored_hashed_pw) {
                    // Password matches
                    session.user = new(types.User)
                    session.user^ = types.User{
                        id = stored_user_id,
                        username = stored_username,
                        email = stored_email,
                        status = .ONLINE, // Set user status to online
                    }
                    log.infof("Client %d: Login successful for user '%s' (ID: %d).", session.id, session.user.username, session.user.id)

                    // TODO: Load server list for the user if that's part of the app features
                    success_resp := protocol.S2C_Login_Success_Message{
                        base = protocol.BaseMessage{type = .S2C_LOGIN_SUCCESS},
                        user = session.user^,
                        servers = make([dynamic]types.Server), // Placeholder
                    }
                    if send_json_message(session.conn, session.id, success_resp) != nil { break }
                } else {
                    // Password does not match
                    log.warnf("Client %d: Incorrect password for username '%s'.", session.id, login_msg.username)
                    failure_resp := protocol.create_s2c_login_failure_message("Invalid username or password.")
                    send_json_message(session.conn, session.id, failure_resp)
                    continue
                }

            case .C2S_REGISTER_USER:
                var reg_msg protocol.C2S_Register_User_Message
                json_err := json.unmarshal(line_bytes, &reg_msg)
                if json_err != nil {
                    log.errorf("Client %d: Failed to unmarshal C2S_REGISTER_USER: %v. Raw: %s", session.id, json_err, string(line_bytes))
                    resp := protocol.create_s2c_registration_failure_message("Invalid registration message format.")
                    send_json_message(session.conn, session.id, resp)
                    continue
                }

                log.infof("Client %d: Processing C2S_REGISTER_USER. Username: '%s', Email: '%s'", session.id, reg_msg.username, reg_msg.email)

                // Validate inputs
                if strings.trim_space(reg_msg.username) == "" || strings.trim_space(reg_msg.email) == "" || reg_msg.password == "" {
                    log.warnf("Client %d: Registration attempt with empty fields. Username: '%s', Email: '%s'", session.id, reg_msg.username, reg_msg.email)
                    resp := protocol.create_s2c_registration_failure_message("Username, email, and password cannot be empty.")
                    send_json_message(session.conn, session.id, resp)
                    continue
                }

                hashed_pw, hash_err := hash_password(reg_msg.password)
                if hash_err != nil { // Should be Error type, not os.Errno
                    log.errorf("Client %d: Password hashing failed for user '%s': %v", session.id, reg_msg.username, hash_err)
                    resp := protocol.create_s2c_registration_failure_message("Server error during registration (hashing).")
                    send_json_message(session.conn, session.id, resp)
                    continue
                }

                // Insert into database
                // Insert into database using parameterized query as per refined hypothetical API
                // db.exec(sql: string, ..args: any) -> (sqlite.Result, sqlite.Error)
                insert_res, err_insert := db.exec(
                    "INSERT INTO users (username, email, hashed_password) VALUES (?, ?, ?)",
                    reg_msg.username,
                    reg_msg.email,
                    hashed_pw,
                )

                if err_insert != nil {
                    log.errorf("Client %d: Failed to insert user '%s' into database: %v", session.id, reg_msg.username, err_insert)
                    error_message := "Server error during registration (database)."
                    // Check for specific error types using the refined hypothetical API
                    // Assuming err_insert is of type sqlite.Error which might have a code or be comparable
                    if err_insert == sqlite.ERR_CONSTRAINT { // Hypothetical error constant
                         error_message = "Username or email already exists."
                    }
                    resp := protocol.create_s2c_registration_failure_message(error_message)
                    send_json_message(session.conn, session.id, resp)
                    continue
                }

                // Get the actual user_id using res.last_insert_rowid() -> i64
                new_user_id := insert_res.last_insert_rowid()
                log.infof("Client %d: User '%s' registered successfully with ID %d.", session.id, reg_msg.username, new_user_id)

                // Send success response with the new user_id (converted to u64)
                success_resp := protocol.create_s2c_registration_success_message(u64(new_user_id), reg_msg.username)
                if send_json_message(session.conn, session.id, success_resp) != nil { break }

            case:
                log.warnf("Client %d: Unhandled message type %v for non-authed user.", session.id, base_req.type)
                failure_resp := protocol.create_s2c_login_failure_message(fmt.tprintf("Unknown request type: %v", base_req.type))
                send_json_message(session.conn, session.id, failure_resp)
            }
        }
    }
}

main :: proc() {
    log.set_default_logger(log.create_console_logger(opt_level=.Debug))

    // Initialize database
    db_handle, err_open := sqlite.open("chat_app.db") // Hypothetical API
    if err_open != nil { // Assuming error is of type sqlite.Error or similar
        log.fatalf("Failed to open/create database: %v", err_open)
        os.exit(1)
        return
    }
    db = db_handle // Assign to global db variable
    log.info("Database chat_app.db opened successfully.")

    create_table_sql := `
    CREATE TABLE IF NOT EXISTS users (
        user_id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        hashed_password TEXT NOT NULL,
        email TEXT UNIQUE NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );`
    // Using the refined hypothetical API: db.exec(sql: string, ..args: any) -> (sqlite.Result, sqlite.Error)
    _, err_create_table := db.exec(create_table_sql) // No arguments for this specific exec
    if err_create_table != nil { // Assuming error is of type sqlite.Error
        log.fatalf("Failed to create users table: %v", err_create_table)
        db.close() // Close the DB if table creation fails
        os.exit(1)
        return
    }
    log.info("Users table checked/created successfully.")

    // Create channels table
    create_channels_table_sql := `
    CREATE TABLE IF NOT EXISTS channels (
        channel_id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_name TEXT UNIQUE NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    );`
    _, err_create_channels_table := db.exec(create_channels_table_sql)
    if err_create_channels_table != nil {
        log.fatalf("Failed to create channels table: %v", err_create_channels_table)
        db.close()
        os.exit(1)
        return
    }
    log.info("Channels table checked/created successfully.")

    // Create messages table
    create_messages_table_sql := `
    CREATE TABLE IF NOT EXISTS messages (
        message_id INTEGER PRIMARY KEY AUTOINCREMENT,
        channel_db_id INTEGER NOT NULL,
        user_db_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        image_path TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY(channel_db_id) REFERENCES channels(channel_id),
        FOREIGN KEY(user_db_id) REFERENCES users(user_id)
    );`
    _, err_create_messages_table := db.exec(create_messages_table_sql)
    if err_create_messages_table != nil {
        log.fatalf("Failed to create messages table: %v", err_create_messages_table)
        db.close()
        os.exit(1)
        return
    }
    log.info("Messages table checked/created successfully.")

    // Load existing channels from DB
    sync.mutex_lock(&channels_mutex) // Lock before modifying chat_channels

    // Hypothetical API: db.query(sql: string, ..args: any) -> ([]map[string]any, sqlite.Error)
    rows, err_load_channels := db.query("SELECT channel_id, channel_name FROM channels")
    if err_load_channels != nil {
        log.errorf("Failed to load existing channels from database: %v", err_load_channels)
        // Not fatal, server can start with no pre-loaded channels other than default.
    } else {
        for row_map in rows {
            channel_id := row_map["channel_id"].(u64) // or i64, then cast
            channel_name := row_map["channel_name"].(string)

            if _, exists := chat_channels[channel_name]; !exists {
                chat_channels[channel_name] = new(ChannelData)
                // Assuming ChannelData might get an 'id' field later. For now, just name.
                chat_channels[channel_name]^ = ChannelData{
                    id       = channel_id, // Store the database ID
                    name     = channel_name,
                    users    = make(map[u64]^ClientSession),
                    messages = make([dynamic]types.Message),
                }
                log.infof("Loaded channel '%s' (ID: %d) from database.", channel_name, channel_id)
            }
        }
    }

    // Initialize default "general" channel if not loaded from DB
    general_channel_name := "general"
    if _, exists := chat_channels[general_channel_name]; !exists {
        // Try to insert "general" channel into DB first, then add to map
        // This handles case where "general" might have been deleted from DB but server restarts
        insert_general_res, err_insert_general := db.exec("INSERT OR IGNORE INTO channels (channel_name) VALUES (?)", general_channel_name)
        if err_insert_general != nil {
            log.errorf("Failed to ensure 'general' channel in DB: %v", err_insert_general)
            // If DB insert fails, create it in-memory only as a fallback for this session
            chat_channels[general_channel_name] = new(ChannelData)
            chat_channels[general_channel_name]^ = ChannelData{ name = general_channel_name, users = make(map[u64]^ClientSession), messages = make([dynamic]types.Message), }
            log.warnf("Created 'general' channel in-memory as DB insert failed.")
        } else {
            general_channel_id := insert_general_res.last_insert_rowid()
            if general_channel_id == 0 { // "INSERT OR IGNORE" might mean 0 if it already existed and was ignored
                // If it already existed, we should have loaded it. If not, query its ID.
                // This part can be complex. For simplicity, if loaded, great. If inserted, great.
                // Re-querying ID if last_insert_rowid is 0 due to IGNORE is an option.
                // For now, we assume if it exists, it was loaded. If newly inserted, we get ID.
                 existing_general_channel_data, err_query_general := db.query_one("SELECT channel_id FROM channels WHERE channel_name = ?", general_channel_name)
                 if err_query_general == nil {
                    general_channel_id = existing_general_channel_data["channel_id"].(i64)
                 } else {
                    log.errorf("Failed to query ID for existing 'general' channel: %v", err_query_general)
                 }
            }

            chat_channels[general_channel_name] = new(ChannelData)
            chat_channels[general_channel_name]^ = ChannelData{
                id       = u64(general_channel_id), // Store the database ID
                name     = general_channel_name,
                users    = make(map[u64]^ClientSession),
                messages = make([dynamic]types.Message),
            }
            log.infof("Ensured 'general' channel (ID: %d) is loaded/created.", general_channel_id)
        }
    }
    sync.mutex_unlock(&channels_mutex)

    address := "127.0.0.1:8080"
    listener, err := net.listen("tcp", address)
    if err != nil { log.errorf("Failed to listen on %s: %v", address, err); os.exit(1); return }
    defer net.close(listener)
    // Using the refined hypothetical API: db.close() -> sqlite.Error
    defer db.close()
    log.infof("Server started, listening on %s.", address)


    for {
        conn, accept_err := net.accept(listener)
        if accept_err != nil {
            log.errorf("Failed to accept connection: %v", accept_err)

            if accept_err == net.EMFILE || accept_err == net.ENFILE { log.critical("Too many open files."); thread.sleep(1 * time.Second) }
            continue
        }

        log.infof("Accepted new connection from %v", net.remote_address(conn))
        go handle_client(conn)
    }
}
