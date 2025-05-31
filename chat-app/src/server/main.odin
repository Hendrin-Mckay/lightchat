package server

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:thread"
import "core:time"
import "core:sync"
// import "core:mem" // No longer explicitly needed for size_of with JSON approach
// import "core:runtime" // No longer explicitly needed for raw_data with JSON approach
import "core:encoding/json"
import "core:strings" // May not be needed if bufio handles all accumulation
import "core:bufio"


import "../shared/types"    // Corrected path for shared types
import "../shared/protocol" // For message protocol definitions

// ClientSession stores information about a connected client
ClientSession :: struct {
    id:          u64,
    conn:        net.Conn,
    user:        ^types.User, // Pointer to User, nil until logged in
    remote_addr: net.Address,   // Cache remote address for logging
}

// Global state for managing clients
connected_clients := make(map[u64]^ClientSession)
clients_mutex     : sync.Mutex
next_client_id    : u64 = 1

// Helper to send a JSON message with a newline
send_json_message :: proc(conn: net.Conn, session_id: u64, message: any) -> (err: net.Error) {
    response_bytes, marshal_err := json.marshal(message)
    if marshal_err != nil {
        log.errorf("Client %d: Failed to marshal message type %T: %v", session_id, message, marshal_err)
        return net.EINVAL // Indicate marshalling error; specific error type might vary
    }

    // Append newline character to delimit the JSON message
    // response_final := append(response_bytes, '\n') // Fails: cannot append rune to []u8
    // Correct way: create a new slice or use a builder if appending many times.
    // For a single newline, creating a new slice is okay.
    newline_char := []u8{'\n'}
    response_final := make([]u8, len(response_bytes) + len(newline_char))
    copy(response_final, response_bytes)
    copy(response_final[len(response_bytes):], newline_char)

    _, write_err := net.write_all(conn, response_final)
    if write_err != nil {
        log.errorf("Client %d: Error sending message type %T: %v", session_id, message, write_err)
        return write_err
    }
    log.debugf("Client %d: Sent message type %T successfully.", session_id, message)
    return nil
}


// handle_client is responsible for managing a single client's lifecycle using JSON messages.
handle_client :: proc(conn: net.Conn) {
    remote_addr := net.remote_address(conn)
    session_id: u64
    session: ^ClientSession // Declare session pointer

    // --- Register client ---
    sync.mutex_lock(&clients_mutex)
    session_id = next_client_id
    next_client_id += 1

    session = new(ClientSession)
    session^ = ClientSession{
        id = session_id,
        conn = conn,
        user = nil,
        remote_addr = remote_addr,
    }
    connected_clients[session_id] = session
    sync.mutex_unlock(&clients_mutex)

    log.infof("Client %v connected with Session ID %d. Waiting for newline-delimited JSON messages...", remote_addr, session_id)

    // Defer unregistration and connection closing
    defer {
        // net.close(conn) // This will be handled by reader.close() if reader wraps conn, or if reader doesn't have close.
                         // bufio.Reader does not have a Close() method, so conn must be closed directly.
        net.close(conn)
        sync.mutex_lock(&clients_mutex)
        delete(connected_clients, session_id)
        sync.mutex_unlock(&clients_mutex)
        log.infof("Client %v (ID %d) disconnected. Active clients: %d", remote_addr, session_id, len(connected_clients))
    }

    // Use a buffered reader to read line by line
    reader := bufio.make_reader(conn, bufio.DEFAULT_BUFFER_SIZE)

    // --- Message reading loop ---
    for {
        line_bytes, err := bufio.read_line_bytes(reader)

        if err != nil {
            if err == net.EOF {
                log.infof("Client %d (%v): Connection closed by peer (EOF).", session.id, remote_addr)
            } else if err == net.EAGAIN { // Should not happen with blocking sockets from accept by default
                log.warnf("Client %d (%v): Read returned EAGAIN, should not happen on blocking socket.", session.id, remote_addr)
                // Potentially sleep briefly and continue, or break if it persists.
                // For now, continue to see if it's transient.
                thread.sleep(50 * time.Millisecond)
                continue
            } else {
                log.errorf("Error reading line from client %d (%v): %v", session.id, remote_addr, err)
            }
            break // Exit loop on EOF or significant error
        }

        if len(line_bytes) == 0 { // Empty line received
            log.debugf("Client %d: Received empty line, continuing.", session.id)
            continue
        }

        log.debugf("Client %d: Received raw line (len %d): %s", session.id, len(line_bytes), string(line_bytes))

        // --- Message Processing Logic ---
        if session.user != nil { // Client is ALREADY LOGGED IN
            // TODO: Deserialize into a base message type (e.g. with just 'type' field)
            // then switch on type to unmarshal into the specific message struct.
            // For now, just log the raw JSON received.
            log.infof("Client %d (%s): Received JSON while logged in: %s",
                        session.id, session.user.username, string(line_bytes))

            // Placeholder: Echo back or specific handling for logged-in users
            // Example: Echoing back what was received for testing purposes.
            // Note: This is a simple echo and doesn't follow the game's protocol.
            // response_echo := fmt.tprintf(`{"status": "received_by_loggedin_user", "original_message": %s}
            // `, string(line_bytes))
            // _, write_err := net.write_string(session.conn, response_echo) // Using session.conn
            // if write_err != nil {
            //    log.errorf("Error writing echo to client %d: %v", session.id, write_err)
            // }

        } else { // Client is NOT LOGGED IN - Expect C2S_LOGIN
            var login_msg protocol.C2S_Login_Message
            json_err := json.unmarshal(line_bytes, &login_msg)

            if json_err != nil {
                log.errorf("Client %d: Failed to unmarshal C2S_LOGIN JSON: %v. Raw data: '%s'",
                            session.id, json_err, string(line_bytes))

                failure_resp := protocol.S2C_Login_Failure_Message{
                    base = protocol.BaseMessage{type = protocol.MessageType.S2C_LOGIN_FAILURE},
                    error_message = "Invalid login message format. Expected JSON.",
                }
                send_json_message(session.conn, session.id, failure_resp)
                // Consider whether to continue or break. If login format is bad,
                // client might be faulty. Continuing gives them another chance.
                continue
            }

            // Optional: Validate message type if it's part of the JSON struct
            // if login_msg.base.type != protocol.MessageType.C2S_LOGIN {
            //     log.warnf("Client %d: Received valid JSON but wrong message type (%v) before login. Expected C2S_LOGIN.", session.id, login_msg.base.type)
            //     failure_resp := protocol.S2C_Login_Failure_Message{ /* ... */ }
            //     send_json_message(session.conn, session.id, failure_resp)
            //     continue
            // }

            log.infof("Client %d: Processing C2S_LOGIN from JSON. Username: '%s'", session.id, login_msg.username)

            // --- Perform Login ---
            // In a real app: validate login_msg.username and login_msg.password against a database.
            // For now, login is always successful if JSON parsing works.
            temp_user := new(types.User)
            temp_user^ = types.User{
                id       = session.id, // Use session_id as user_id for simplicity
                username = login_msg.username, // Use username from JSON
                email    = fmt.tprintf("%s@example.com", login_msg.username), // Dummy email
                status   = types.UserStatus.ONLINE,
            }
            session.user = temp_user // Assign user to session

            log.infof("Client %d: Login successful for user '%s'.", session.id, session.user.username)

            // --- Send S2C_LOGIN_SUCCESS ---
            success_resp := protocol.S2C_Login_Success_Message{
                base    = protocol.BaseMessage{type = protocol.MessageType.S2C_LOGIN_SUCCESS},
                user    = session.user^, // Send a copy of the user data
                servers = make([dynamic]types.Server), // Empty server list
            }
            send_err := send_json_message(session.conn, session.id, success_resp)
            if send_err != nil {
                // Error already logged by send_json_message.
                // Decide if this is fatal for the connection. If we can't send success, client is in limbo.
                break
            }
        }
    }
}

main :: proc() {
    log.set_default_logger(log.create_console_logger(opt_level=.Debug))

    address := "127.0.0.1:8080"
    listener, err := net.listen("tcp", address)
    if err != nil {
        log.errorf("Failed to listen on %s: %v", address, err)
        os.exit(1)
        return
    }
    defer net.close(listener)

    log.infof("Server started, listening on %s. Expecting newline-delimited JSON.", address)

    for {
        conn, accept_err := net.accept(listener)
        if accept_err != nil {
            log.errorf("Failed to accept connection: %v", accept_err)
            if accept_err == net.EMFILE || accept_err == net.ENFILE {
                log.critical("Too many open files, server might be unstable. Sleeping for 1s.")
                thread.sleep(1 * time.Second)
            }
            continue
        }

        log.infof("Accepted new connection from %v", net.remote_address(conn))
        go handle_client(conn)
    }
}
