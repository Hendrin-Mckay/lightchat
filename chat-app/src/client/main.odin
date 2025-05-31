package client

import rl "vendor:raylib" // Assuming raylib is in a vendor directory or system path

// Forward declarations for procedures to be defined later
init_app :: proc(app: ^App) ---
update_app :: proc(app: ^App) ---
draw_app :: proc(app: ^App) ---
cleanup_app :: proc(app: ^App) ---

// Forward declarations for types that might be in other files
User :: struct {} // Placeholder
Server :: struct {} // Placeholder
Channel :: struct {} // Placeholder
UIManager :: struct {} // Placeholder
NetworkClient :: struct {} // Placeholder


AppState :: enum {
    LOGIN,
    MAIN_CHAT,
    SETTINGS,
}

App :: struct {
    state:           AppState,
    window_width:    i32,
    window_height:   i32,
    current_user:    ^User,          // Placeholder
    current_server:  ^Server,        // Placeholder
    current_channel: ^Channel,       // Placeholder
    ui_manager:      ^UIManager,     // Placeholder
    network_client:  ^NetworkClient, // Placeholder
    image_cache:     map[string]rl.Texture2D,
}

main :: proc() {
    app := App{
        window_width = 1200,
        window_height = 800,
        state = .LOGIN,
    }

    rl.InitWindow(app.window_width, app.window_height, "Discord Clone")
    rl.SetTargetFPS(60)

    // init_app(&app) // Call to placeholder

    for !rl.WindowShouldClose() {
        // update_app(&app) // Call to placeholder

        rl.BeginDrawing()
        rl.ClearBackground(rl.RAYWHITE)
        // draw_app(&app) // Call to placeholder
        rl.DrawText("Basic Raylib Window!", 190, 200, 20, rl.LIGHTGRAY)
        rl.EndDrawing()
    }

    // cleanup_app(&app) // Call to placeholder
    rl.CloseWindow()
}

// Placeholder implementations (to be expanded in later steps)
init_app :: proc(app: ^App) {
    // Initialize application state, UI, network, etc.
    // For now, this can be empty or have minimal setup.
    app.image_cache = make(map[string]rl.Texture2D)
}

update_app :: proc(app: ^App) {
    // Handle input, update game logic, network events, etc.
}

draw_app :: proc(app: ^App) {
    // Draw all UI elements based on app.state
}

cleanup_app :: proc(app: ^App) {
    // Free resources, close connections, etc.
    // Example: cleanup image cache if it were populated
    // for path, texture in app.image_cache {
    //     rl.UnloadTexture(texture)
    // }
    // delete(app.image_cache)
}
