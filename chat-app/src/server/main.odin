package main

import "core:fmt"

// Adjust import paths based on your actual project structure if they differ.
// These assume 'main.odin' is in 'src/server/' and 'types.odin' is in 'src/shared/'.
// And 'server.odin' is in 'src/server/websocket/'.
import shared "../shared" // Assuming types.odin is here
import ws "./websocket"   // Assuming server.odin is here

main :: proc() {
    fmt.println("Starting Chat Server...")

    // Initialize the WebSocketServer struct
    // The actual fields like port, clients, channels, mutex will be set
    // either here or within the start_server procedure itself.
    // For now, we create an empty instance and let start_server populate it,
    // or pass configuration to start_server.

    // Option 1: Initialize with some default values
    server_instance := ws.WebSocketServer{
        port = 8080, // Default port
        // clients and channels maps will be initialized in start_server
        // mutex will also be initialized where it's first needed or in start_server
    }

    // Option 2: Zero-initialized struct, if start_server handles all setup
    // server_instance: ws.WebSocketServer

    // Start the server
    // If start_server is designed to take a pointer and modify it:
    ws.start_server(&server_instance)

    // If start_server is designed to take parameters and return a server or manage its own instance:
    // ws.start_server(8080) // Example if port is passed directly

    fmt.println("Chat Server Exited.") // Should not be reached if server runs indefinitely
}
