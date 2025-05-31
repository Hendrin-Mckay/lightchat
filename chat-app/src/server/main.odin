package server

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:thread"
import "core:time"
import "core:sync"
import "core:mem" // For size_of
import "core:runtime" // For raw_data if needed, or bit_cast

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

// handle_client is responsible for managing a single client's lifecycle.
handle_client :: proc(conn: net.Conn) {
    remote_addr := net.remote_address(conn)
    session_id: u64
    session: ^ClientSession // Declare session pointer

    // --- Register client ---
    sync.mutex_lock(&clients_mutex)
    session_id = next_client_id
    next_client_id += 1

    // Use 'session' directly as it's declared above
    session = new(ClientSession)
    session^ = ClientSession{
        id = session_id,
        conn = conn,
        user = nil,
        remote_addr = remote_addr,
    }
    connected_clients[session_id] = session
    sync.mutex_unlock(&clients_mutex)

    log.infof("Client %v connected with Session ID %d", remote_addr, session_id)

    defer {
        net.close(conn)
        sync.mutex_lock(&clients_mutex)
        delete(connected_clients, session_id)
        sync.mutex_unlock(&clients_mutex)
        log.infof("Client %v (ID %d) disconnected. Active clients: %d", remote_addr, session_id, len(connected_clients))
    }

    // --- Message reading loop ---
    buffer := make([]u8, 4096)
    for {
        n, err := net.read(conn, buffer)
        if err != nil {
            if err == net.EOF {
                log.infof("Client %d (%v) closed connection (EOF).", session.id, remote_addr)
            } else if err != net.EAGAIN && err != net.EINTR {
                log.errorf("Error reading from client %d (%v): %v", session.id, remote_addr, err)
            }
            break
        }

        if n == 0 {
            log.infof("Client %d (%v) disconnected (0 bytes read).", session.id, remote_addr)
            break
        }

        // --- Message Processing Logic ---
        log.debugf("Received %d bytes from client %d (%v).", n, session.id, remote_addr)

        // Placeholder for proper deserialization.
        // We assume the first part of the message is BaseMessage to get the type.
        // This is a simplification and requires the client to send data in this exact format.
        if n < size_of(protocol.BaseMessage) {
            log.debugf("Client %d: Received data too short to be a BaseMessage (%d bytes). Min required: %d",
                        session.id, n, size_of(protocol.BaseMessage))
            continue
        }

        // UNSAFE: Directly casting buffer to BaseMessage. This is a placeholder.
        // Assumes BaseMessage is blittable and at the start of the buffer.
        // In Odin, `raw_data` and `transmute` or `bit_cast` might be used for such low-level operations.
        // Using `(^protocol.BaseMessage)(raw_data(buffer[:size_of(protocol.BaseMessage)]))^` as per example.
        // However, direct pointer casting `(^protocol.BaseMessage)&buffer[0]` is more common if alignment is guaranteed.
        // Let's use bit_cast for a slightly safer interpretation if available and appropriate.
        // For simplicity and consistency with the prompt's example, using raw_data approach.
        // `raw_data` returns a rawptr, needs casting to ^protocol.BaseMessage.

        // IMPORTANT: The following casting is a major simplification for protocol handling.
        // Real applications need robust deserialization (e.g., JSON, Protobuf, custom binary format).
        // Odin strings in structs like C2S_Login_Message make direct casting of the whole struct invalid
        // if strings are involved in the casted part. We only cast BaseMessage here.

        base_msg_ptr := (^protocol.BaseMessage)(runtime.raw_data(buffer[:size_of(protocol.BaseMessage)]))
        msg_type := base_msg_ptr.type
        // log.debugf("Client %d: Interpreted message type: %v", session.id, msg_type)


        if session.user != nil { // Client is already logged in
            log.infof("Client %d (%s): Received message (type %v). Processing...",
                        session.id, session.user.username, msg_type)
            // Placeholder for handling other message types from logged-in users
            switch msg_type {
            case protocol.MessageType.C2S_SEND_MESSAGE:
                // Placeholder: Will be implemented in a future task.
                // login_msg_ptr := (^protocol.C2S_Send_Message_Message)(runtime.raw_data(buffer[:n]))
                // send_msg := login_msg_ptr^
                log.infof("Client %d (%s): Received C2S_SEND_MESSAGE. Content (placeholder): (not extracted)",
                            session.id, session.user.username)
                // Actual handling would involve deserializing send_msg.content, etc.
            case protocol.MessageType.C2S_JOIN_CHANNEL:
                log.infof("Client %d (%s): Received C2S_JOIN_CHANNEL (placeholder).", session.id, session.user.username)
            case protocol.MessageType.C2S_CREATE_CHANNEL:
                log.infof("Client %d (%s): Received C2S_CREATE_CHANNEL (placeholder).", session.id, session.user.username)
            // Add other cases for logged-in users as features are added
            case: // Default case for unknown message types from logged-in user
                log.warnf("Client %d (%s): Received unknown/unhandled message type (%v).",
                            session.id, session.user.username, msg_type)
            }
        } else { // Client is NOT logged in
            if msg_type == protocol.MessageType.C2S_LOGIN {
                log.infof("Client %d: Processing C2S_LOGIN request.", session.id)

                // Placeholder Deserialization for C2S_Login_Message:
                // As noted, direct casting of C2S_Login_Message is unsafe due to string fields.
                // We are simulating the extraction of username for the subtask's purpose.
                // In a real scenario, one would parse `login_msg.username` and `login_msg.password`
                // from `buffer[size_of(protocol.BaseMessage):n]` using a proper deserializer.

                // Simulate successful login:
                // For this subtask, any C2S_LOGIN attempt is successful.
                // Password is not checked. Username is hardcoded/generated.
                temp_user := new(types.User)
                temp_user^ = types.User{
                    id       = session.id, // Use session_id as user_id for simplicity
                    username = fmt.tprintf("User_%d", session.id), // Generate a username
                    email    = fmt.tprintf("user%d@example.com", session.id), // Dummy email
                    status   = types.UserStatus.ONLINE,
                    // avatar field is empty string by default
                }
                // CRITICAL: Lock mutex before modifying session shared across threads,
                // if session fields (like 'user') can be accessed by other threads.
                // For now, 'session' is primarily managed by this thread, but assigning 'user'
                // makes it visible. It's safer to lock if there's any doubt.
                // However, typical session objects are confined to their handler thread until published.
                // Let's assume session object itself is not concurrently accessed for field modification for now,
                // but the connected_clients map is.
                session.user = temp_user

                log.infof("Client %d: Login successful. Assigned username: %s",
                            session.id, session.user.username)

                // Placeholder for sending S2C_LOGIN_SUCCESS:
                // Actual message creation and serialization will be a future task.
                // s2c_login_success := protocol.S2C_Login_Success_Message {
                //     base = protocol.BaseMessage{type = protocol.MessageType.S2C_LOGIN_SUCCESS},
                //     user = session.user^, // Send a copy of the user data
                //     servers = nil, // No servers for now
                // }
                // serialized_response, ser_err := protocol.serialize_message(s2c_login_success) // Placeholder
                // if ser_err == nil {
                //    net.write(conn, serialized_response)
                // }
                log.debugf("Client %d: Would send S2C_LOGIN_SUCCESS to %s.",
                            session.id, session.user.username)

            } else {
                log.warnf("Client %d: Received non-LOGIN message (type %v) before login. Ignoring.",
                            session.id, msg_type)
                // Optionally, send an S2C_ERROR message back to the client.
                // log.debugf("Client %d: Would send S2C_ERROR (NotLoggedIn) to client.", session.id)
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

    log.infof("Server started, listening on %s.", address)

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
