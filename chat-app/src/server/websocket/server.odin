package websocket

import "core:fmt"
import "core:net"
import "core:sync"
import "core:thread"
import "core:os"
// import "core:slice" // Removed as not used

import shared "../../shared"


WebSocketServer :: struct {
    port:        int,
    clients:     map[u64]^Client,

    channels:    map[u64]^shared.Channel,
    mutex:       sync.Mutex,
    next_client_id: u64,
}

Client :: struct {
    id:         u64,

    connection: net.TCP_Socket,
    user:       ^shared.User,
    current_channel_id: u64,
}

// New struct to pass arguments to handle_client_thread_proc
ClientHandlerArgs :: struct {
    server: ^WebSocketServer,
    client: ^Client,
}

// Renamed to avoid conflict if we had an old one, and to match thread proc signature
handle_client_thread_proc :: proc(data: rawptr) {
    args := (^ClientHandlerArgs)(data)
    server := args.server
    client := args.client

    // Free the arguments struct itself, as it was heap-allocated for the thread
    defer free(args)

    fmt.printf("Client %v connected from %v\n", client.id, client.connection.remote_endpoint)

    // Main loop for handling client communication
    buffer := make([]u8, 4096) // Increased buffer size
    running := true
    for running {
        n, err := net.read_from_socket(client.connection, buffer)

        if err != nil {
            if err == .EOF || err == .Connection_Reset || err == .Connection_Aborted {
                fmt.printf("Client %v disconnected (%v).\n", client.id, err)
            } else {
                // Log other errors, e.g., .No_More_Data could be non-fatal depending on protocol
                // For now, assume any error other than EOF/Reset/Aborted might be worth logging differently.
                fmt.printf("Error reading from client %v: %v\n", client.id, err)
            }
            running = false // Exit loop on any error or EOF
            continue
        }

        if n > 0 {
            message_data := buffer[:n]
            fmt.printf("Client %v sent %v bytes: %s\n", client.id, n, string(message_data))
            // Placeholder: Echo back to client for testing
            // write_err := net.write_to_socket(client.connection, message_data)
            // if write_err != nil {
            //     fmt.printf("Error writing back to client %v: %v\n", client.id, write_err)
            //     running = false // Stop if we can't write back
            // }
        }
        // If n == 0 and no error, it might mean a keep-alive or empty packet, continue loop
    }

    // Cleanup: close socket, remove from server.clients, free client memory
    net.close_socket(client.connection)
    fmt.printf("Client %v connection closed.\n", client.id)

    // Remove client from server's list
    sync.mutex_lock(&server.mutex)
    // Check if client is still in the map before deleting, though it should be
    if _, ok := server.clients[client.id]; ok {
        delete(server.clients, client.id)
        fmt.printf("Client %v removed from server list. Active clients: %v\n", client.id, len(server.clients))
    }
    sync.mutex_unlock(&server.mutex)

    // Free the client struct itself, as it was heap-allocated
    free(client)
    fmt.printf("Client %v resources freed.\n", client.id)
}


start_server :: proc(server: ^WebSocketServer) {
    fmt.printf("Starting server on port %v...\n", server.port)

    server.clients = make(map[u64]^Client)
    server.channels = make(map[u64]^shared.Channel)
    server.next_client_id = 1
    // server.mutex is zero-initialized

    address := fmt.tprintf("0.0.0.0:%v", server.port)
    listener, listen_err := net.listen_tcp(address)
    if listen_err != nil {
        fmt.eprintf("Error listening on port %v: %v\n", server.port, listen_err)
        os.exit(1)
        return
    }
    defer net.close_socket(listener)

    fmt.printf("Server listening on %s\n", address)

    for {
        conn, accept_err := net.accept_tcp(listener)
        if accept_err != nil {
            fmt.eprintf("Error accepting connection: %v\n", accept_err)
            continue
        }

        client_id := server.next_client_id
        server.next_client_id += 1

        client_ptr := new(Client)
        client_ptr^ = Client{
            id = client_id,
            connection = conn,
        }

        // Prepare arguments for the thread
        handler_args_ptr := new(ClientHandlerArgs)
        handler_args_ptr^ = ClientHandlerArgs{
            server = server,
            client = client_ptr,
        }

        sync.mutex_lock(&server.mutex)
        server.clients[client_id] = client_ptr
        sync.mutex_unlock(&server.mutex)

        fmt.printf("Accepted connection from %v, assigned client ID %v. Spawning thread...\n", conn.remote_endpoint, client_id)

        // Spawn a new thread to handle the client
        err_thread := thread.create_and_run_proc(handle_client_thread_proc, handler_args_ptr)
        if err_thread != nil {
            fmt.eprintf("Failed to create thread for client %v: %v\n", client_id, err_thread)

            sync.mutex_lock(&server.mutex)
            delete(server.clients, client_id)
            sync.mutex_unlock(&server.mutex)

            free(client_ptr)
            free(handler_args_ptr) // Also free args if thread fails
            net.close_socket(conn)
        }
    }

}
