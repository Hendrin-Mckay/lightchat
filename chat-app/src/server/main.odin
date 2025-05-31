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


import "../shared/types"
import "../shared/protocol"

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
                delete(old_channel.users, session.id)
                log.infof("Client %d removed from channel '%s' due to disconnect.", session.id, session.current_channel_name)
                // TODO: Broadcast S2C_User_Left_Channel_Message to other users in old_channel
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
                    sync.mutex_unlock(&channels_mutex)
                    log.infof("Client %d (%s) joined channel '%s'. Users: %d", session.id, session.user.username, join_msg.channel_name, len(target_channel.users))
                    join_response := protocol.S2C_User_Joined_Channel_Message{ base = protocol.BaseMessage{type = .S2C_USER_JOINED_CHANNEL}, channel_name = join_msg.channel_name, user = session.user^, }
                    send_json_message(session.conn, session.id, join_response)
                } else {
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

                // Create the message
                msg_id := u64(time.tick_now()) // Simplistic ID, not collision-proof for high volume
                new_chat_message := types.Message{
                    id = msg_id,
                    author_id = session.user.id,
                    channel_name = session.current_channel_name,
                    content = send_msg_req.content,
                    image_path = send_msg_req.image_path, // Assuming client sends empty string if no image
                    timestamp = time.now(),
                    edited = false,
                }

                // Store message in channel history
                append(&current_channel_data.messages, new_chat_message)
                // TODO: Optional: Limit message history size (e.g., cap at N messages)

                // Prepare broadcast payload
                broadcast_payload := protocol.S2C_New_Message_Message{
                    base = protocol.BaseMessage{type = protocol.MessageType.S2C_NEW_MESSAGE},
                    message = new_chat_message,
                }

                log.infof("Broadcasting msg ID %v in '%s' to %d users.", msg_id, current_channel_data.name, len(current_channel_data.users))
                for _, user_in_channel := range current_channel_data.users {
                    if user_in_channel != nil && user_in_channel.conn != nil {
                        log.debugf("Sending msg ID %v to user %d (%s)", msg_id, user_in_channel.id, user_in_channel.user.username)
                        err_send := send_json_message(user_in_channel.conn, user_in_channel.id, broadcast_payload)
                        if err_send != nil {
                             log.errorf("Failed to send message (ID %v) to user %d (%s) in channel '%s': %v", msg_id, user_in_channel.id, user_in_channel.user.username, current_channel_data.name, err_send)
                             // Decide if we should remove this user or mark them as problematic
                        }
                    } else {
                         log.warnf("Skipped broadcast to nil session/conn for session ID %v in channel '%s'", user_in_channel.id if user_in_channel != nil else "unknown", current_channel_data.name)
                    }
                }
                sync.mutex_unlock(&channels_mutex)
                log.infof("Client %d (%s) sent message to '%s': \"%s\"", session.id, session.user.username, session.current_channel_name, send_msg_req.content)

            case:
                log.warnf("Client %d (%s): Unhandled message type %v", session.id, session.user.username, base_msg.type)
                err_resp := protocol.S2C_Error_Message{ base = protocol.BaseMessage{type = .S2C_ERROR}, error_message = "Unhandled message type.", original_request_type = base_msg.type }
                send_json_message(session.conn, session.id, err_resp)
            }
        } else { // Client is NOT LOGGED IN
            var login_msg protocol.C2S_Login_Message
            json_err := json.unmarshal(line_bytes, &login_msg)
            if json_err != nil {
                log.errorf("Client %d: Failed to unmarshal C2S_LOGIN JSON: %v. Raw: '%s'", session.id, json_err, string(line_bytes))
                failure_resp := protocol.S2C_Login_Failure_Message{ base = protocol.BaseMessage{type = .S2C_LOGIN_FAILURE}, error_message = "Invalid login message format." }
                send_json_message(session.conn, session.id, failure_resp)
                continue
            }
            log.infof("Client %d: Processing C2S_LOGIN from JSON. Username: '%s'", session.id, login_msg.username)
            temp_user := new(types.User); temp_user^ = types.User{ id = session.id, username = login_msg.username, email = fmt.tprintf("%s@example.com", login_msg.username), status = .ONLINE, }
            session.user = temp_user
            log.infof("Client %d: Login successful for user '%s'.", session.id, session.user.username)
            success_resp := protocol.S2C_Login_Success_Message{ base = protocol.BaseMessage{type = .S2C_LOGIN_SUCCESS}, user = session.user^, servers = make([dynamic]types.Server), }
            if send_json_message(session.conn, session.id, success_resp) != nil { break }
        }
    }
}

main :: proc() {
    log.set_default_logger(log.create_console_logger(opt_level=.Debug))
    sync.mutex_lock(&channels_mutex)
    general_channel_name := "general"
    if _, exists := chat_channels[general_channel_name]; !exists {
        chat_channels[general_channel_name] = new(ChannelData)
        chat_channels[general_channel_name]^ = ChannelData{ name = general_channel_name, users = make(map[u64]^ClientSession), messages = make([dynamic]types.Message), }
        log.infof("Default channel '%s' created.", general_channel_name)
    } else { log.warnf("Default channel '%s' already exists.", general_channel_name) }
    sync.mutex_unlock(&channels_mutex)

    address := "127.0.0.1:8080"
    listener, err := net.listen("tcp", address)
    if err != nil { log.errorf("Failed to listen on %s: %v", address, err); os.exit(1); return }
    defer net.close(listener)
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
