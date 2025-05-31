package client

import rl "vendor:raylib"
import "core:net"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:encoding/json"
import "core:bufio"         // Added for buffered reader
import "../shared/protocol" // For C2S_Login_Message and S2C messages
import "../shared/types"    // Added for types.User

// Helper to convert a null-terminated u8 buffer (C string) to an Odin string
cstring_buffer_to_string :: proc(buffer: []u8) -> string {
    length := 0
    for length < len(buffer) && buffer[length] != 0 {
        length += 1
    }
    return string(buffer[:length])
}

// Forward declarations for procedures to be defined later
init_app :: proc(app: ^App) ---
update_app :: proc(app: ^App) ---
draw_app :: proc(app: ^App) ---
cleanup_app :: proc(app: ^App) ---

AppState :: enum {
    LOGIN,
    MAIN_CHAT,
}

App :: struct {
    state:           AppState,
    window_width:    i32,
    window_height:   i32,
    image_cache:     map[string]rl.Texture2D,

    username_buffer: [128]u8,
    password_buffer: [128]u8,
    username_box_active: bool,
    password_box_active: bool,
    login_error_message: string,

    conn: net.Conn,
    reader: bufio.Reader, // Added for reading responses
    is_connecting: bool,
    is_connected: bool,
    login_attempted_this_connection: bool,
    logged_in_user: ^types.User, // Added to store user data
}

main :: proc() {
    log.set_default_logger(log.create_console_logger())
    app := App{
        window_width = 1200,
        window_height = 800,
        state = .LOGIN,
    }

    rl.InitWindow(app.window_width, app.window_height, "Chat App Client")
    rl.SetTargetFPS(60)
    init_app(&app)

    for !rl.WindowShouldClose() {
        update_app(&app)
        rl.BeginDrawing()
        rl.ClearBackground(rl.RAYWHITE)
        draw_app(&app)
        rl.EndDrawing()
    }

    cleanup_app(&app)
    rl.CloseWindow()
}

init_app :: proc(app: ^App) {
    app.image_cache = make(map[string]rl.Texture2D)
    log.info("Application initialized.")
}

// Disconnects and resets connection-related state
disconnect_and_reset :: proc(app: ^App, reason: string) {
    if app.conn != nil {
        net.close(app.conn)
        app.conn = nil
    }
    app.is_connected = false
    app.is_connecting = false
    app.login_attempted_this_connection = false
    // app.reader = nil // bufio.Reader doesn't need explicit destroy if it's just a struct. Re-make on new conn.
    if reason != "" {
        app.login_error_message = reason
    }
    log.infof("Disconnected. Reason: %s", reason)
}


update_app :: proc(app: ^App) {
    switch app.state {
    case .LOGIN:
        // Try to read response if login was sent and we are not yet fully logged in
        if app.is_connected && app.login_attempted_this_connection && app.logged_in_user == nil && app.reader.buf != nil {
            // log.debug("Attempting to read login response...") // Can be too spammy
            line_bytes, read_err := bufio.read_line_bytes(&app.reader)

            if read_err != nil {
                if read_err == net.EOF {
                    log.info("Server closed connection while awaiting login response.")
                    disconnect_and_reset(app, "Connection lost: Server closed the connection.")
                } else if read_err == bufio.Error.Buffer_Full { // Read buffer is full but no newline
                     log.warn("Read buffer full, but no newline. Possible malformed message or very long line.")
                     // Depending on protocol, might try to read more or disconnect.
                     disconnect_and_reset(app, "Network error: Incomplete message from server.")
                } else {
                    // Other errors like net.EPIPE, net.ECONNRESET etc.
                    log.errorf("Error reading login response: %v", read_err)
                    disconnect_and_reset(app, "Network error receiving response.")
                }
            } else if len(line_bytes) > 0 { // Successfully read a line
                log.debugf("Received line from server: %s", string(line_bytes))
                var base_resp: protocol.BaseMessage
                json_err := json.unmarshal(line_bytes, &base_resp)
                if json_err != nil {
                    log.errorf("Failed to unmarshal base response JSON: %v. Raw: %s", json_err, string(line_bytes))
                    app.login_error_message = "Error: Invalid response from server."
                    // Not disconnecting here, server might send another valid message or client can retry.
                } else {
                    switch base_resp.type {
                    case .S2C_LOGIN_SUCCESS:
                        var success_msg: protocol.S2C_Login_Success_Message
                        json_err_s := json.unmarshal(line_bytes, &success_msg)
                        if json_err_s != nil {
                            log.errorf("Failed to unmarshal S2C_LOGIN_SUCCESS: %v. Raw: %s", json_err_s, string(line_bytes))
                            app.login_error_message = "Error: Malformed login success response."
                        } else {
                            app.logged_in_user = new(types.User)
                            app.logged_in_user^ = success_msg.user
                            app.login_error_message = "Login Successful!" // This will be briefly visible
                            log.infof("Login successful for user: %s (ID: %d)", app.logged_in_user.username, app.logged_in_user.id)
                            app.state = .MAIN_CHAT
                            // app.login_attempted_this_connection = false // No longer needed as we switch state
                        }
                    case .S2C_LOGIN_FAILURE:
                        var failure_msg: protocol.S2C_Login_Failure_Message
                        json_err_f := json.unmarshal(line_bytes, &failure_msg)
                        if json_err_f != nil {
                            log.errorf("Failed to unmarshal S2C_LOGIN_FAILURE: %v. Raw: %s", json_err_f, string(line_bytes))
                            app.login_error_message = "Error: Malformed login failure response."
                        } else {
                            app.login_error_message = fmt.tprintf("Login failed: %s", failure_msg.error_message)
                            log.warnf("Login failed: %s", failure_msg.error_message)
                        }
                        app.login_attempted_this_connection = false // Allow another login attempt with current UI data
                        // Optionally disconnect: disconnect_and_reset(app, "Login failed by server.")
                    case: // Default / Unexpected message
                        log.warnf("Received unexpected message type (%v) from server after login attempt.", base_resp.type)
                        app.login_error_message = "Error: Unexpected response from server."
                        // app.login_attempted_this_connection = false // Allow retry or not? Depends on policy.
                    }
                }
            } // else: empty line received, ignore or log.debug
        }

        // Send login message if connected, not connecting, and not yet attempted for this session
        if app.is_connected && !app.is_connecting && !app.login_attempted_this_connection && app.logged_in_user == nil {
            // This block is for SENDING the login request
            username_str := cstring_buffer_to_string(app.username_buffer[:])
            password_str := cstring_buffer_to_string(app.password_buffer[:])

            if username_str == "" {
                app.login_error_message = "Username cannot be empty."
                disconnect_and_reset(app, "Username cannot be empty.") // Disconnect if validation fails
                return
            }

            log.info("Preparing to send C2S_LOGIN message...")
            login_payload := protocol.C2S_Login_Message{
                base     = protocol.BaseMessage{type = protocol.MessageType.C2S_LOGIN},
                username = username_str,
                password = password_str,
            }
            json_bytes, marshal_err := json.marshal(login_payload)
            if marshal_err != nil {
                log.errorf("Failed to marshal login message: %v", marshal_err)
                disconnect_and_reset(app, "Client error: Failed to prepare login data.")
            } else {
                final_payload := make([]u8, len(json_bytes) + 1); copy(final_payload, json_bytes); final_payload[len(json_bytes)] = '\n'
                _, write_err := net.write_all(app.conn, final_payload)
                if write_err != nil {
                    log.errorf("Failed to send login message: %v", write_err)
                    disconnect_and_reset(app, "Network error: Failed to send login data.")
                } else {
                    log.infof("Login message sent successfully. Username: %s", username_str)
                    app.login_error_message = "Login sent. Waiting for server response..."
                    app.login_attempted_this_connection = true
                }
            }
        // Handle UI interaction for initiating connection if not connected/connecting
        } else if !app.is_connected && !app.is_connecting {
            // This block is for INITIATING connection
            username_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) - 60, 200, 30 }
            password_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) - 20, 200, 30 }
            login_button_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) + 20, 200, 40 }

            if rl.GuiTextBox(username_rect, app.username_buffer[:], &app.username_box_active) { if app.username_box_active { app.password_box_active = false } }
            if rl.GuiTextBox(password_rect, app.password_buffer[:], &app.password_box_active) { if app.password_box_active { app.username_box_active = false } }

            if rl.GuiButton(login_button_rect, "Login") {
                app.is_connecting = true; app.login_error_message = ""; app.login_attempted_this_connection = false
                log.info("Login button clicked. Attempting to connect...")

                conn, err := net.dial("tcp", "127.0.0.1:8080")
                if err != nil {
                    log.errorf("Failed to connect to server: %v", err)
                    disconnect_and_reset(app, fmt.tprintf("Connection failed: %v", err))
                } else {
                    log.info("Network connection established. Initializing reader.")
                    app.is_connecting = false; app.is_connected = true; app.conn = conn
                    // Initialize reader for the new connection
                    app.reader = bufio.make_reader(app.conn, bufio.DEFAULT_BUFFER_SIZE)
                }
            }
        }
    case .MAIN_CHAT:
        // Main chat logic here (future task)
        // For now, just ensure we don't fall through to login logic
        if app.conn == nil || !app.is_connected { // Connection lost somehow
            log.warn("Connection lost while in MAIN_CHAT state. Returning to LOGIN.")
            app.state = .LOGIN
            disconnect_and_reset(app, "Connection lost.")
        }
        break
    }
}

draw_app :: proc(app: ^App) {
    switch app.state {
    case .LOGIN:
        username_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) - 60, 200, 30 }
        password_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) - 20, 200, 30 }
        login_button_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) + 20, 200, 40 }

        button_text := "Login"
        if app.is_connecting { button_text = "Connecting..." }
        else if app.is_connected && app.login_attempted_this_connection && app.logged_in_user == nil { button_text = "Verifying..." }
        else if app.is_connected && !app.login_attempted_this_connection { button_text = "Send Credentials" } // Should quickly change

        rl.GuiTextBox(username_rect, app.username_buffer[:], &app.username_box_active)
        rl.GuiTextBox(password_rect, app.password_buffer[:], &app.password_box_active)
        rl.GuiButton(login_button_rect, button_text)

        status_text_y := login_button_rect.y + login_button_rect.height + 20
        current_status_message := ""
        status_color := rl.GRAY

        if app.login_error_message != "" {
            current_status_message = app.login_error_message
            if strings.contains(strings.to_lower(app.login_error_message), "failed") ||
               strings.contains(strings.to_lower(app.login_error_message), "error") {
                status_color = rl.RED
            } else if strings.contains(app.login_error_message, "Waiting for server") ||
                      strings.contains(app.login_error_message, "Login sent") {
                 status_color = rl.ORANGE
            } else { status_color = rl.BLACK }
        } else if app.is_connecting {
            current_status_message = "Connecting to server..."; status_color = rl.ORANGE
        } else if app.is_connected && app.login_attempted_this_connection && app.logged_in_user == nil {
            current_status_message = "Login sent. Waiting for server response..."; status_color = rl.SKYBLUE
        } else if app.is_connected {
             current_status_message = "Connected. Ready to send login."; status_color = rl.GREEN
        } else {
             current_status_message = "Please enter your credentials."
        }
        rl.DrawText(current_status_message, i32(login_button_rect.x), i32(status_text_y), 20, status_color)

    case .MAIN_CHAT:
        if app.logged_in_user != nil {
            welcome_text := fmt.tprintf("Welcome, %s!", app.logged_in_user.username)
            text_width := rl.MeasureText(welcome_text, 30)
            rl.DrawText(welcome_text, (app.window_width - text_width)/2, app.window_height/2 - 40, 30, rl.DARKGREEN)
        } else { // Should not happen if state is MAIN_CHAT
            rl.DrawText("Error: No user data in MAIN_CHAT state.", 190, 200, 20, rl.RED)
        }
    }
}

cleanup_app :: proc(app: ^App) {
    if app.conn != nil {
        log.info("Closing network connection.")
        net.close(app.conn)
        app.conn = nil
        app.is_connected = false
    }
    // Free user struct if allocated
    if app.logged_in_user != nil {
        free(app.logged_in_user) // Assuming it was allocated with new()
        app.logged_in_user = nil
    }
    log.info("Application cleanup finished.")
}
