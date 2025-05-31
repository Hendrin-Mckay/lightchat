package client

import rl "vendor:raylib"
import "core:net"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:encoding/json"

import "core:bufio"
import "core:time"
import "core:container/dynarray"

import "../shared/protocol"
import "../shared/types"


// Helper to convert a null-terminated u8 buffer (C string) to an Odin string
cstring_buffer_to_string :: proc(buffer: []u8) -> string {
    length := 0
    for length < len(buffer) && buffer[length] != 0 {
        length += 1
    }
    return string(buffer[:length])
}

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


    // Network state
    conn: net.Conn,
    reader: bufio.Reader,
    is_connecting: bool,
    is_connected: bool,
    login_attempted_this_connection: bool,

    // Logged-in user & current context
    logged_in_user: ^types.User,
    current_channel_name: string,

    // Chat message input
    chat_message_buffer: [256]u8,
    chat_message_box_active: bool,
    current_chat_messages: [dynamic]types.Message,
    chat_error_message: string, // For errors specific to chat view (e.g. send failed)

}

main :: proc() {
    log.set_default_logger(log.create_console_logger())
    app := App{
        window_width = 1200,
        window_height = 800,
        state = .LOGIN,
        current_chat_messages = make([dynamic]types.Message),
        current_channel_name = "",
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

disconnect_and_reset :: proc(app: ^App, reason: string) {
    if app.conn != nil {
        net.close(app.conn)
        app.conn = nil
    }
    app.is_connected = false
    app.is_connecting = false
    app.login_attempted_this_connection = false
    if reason != "" {
        // If in LOGIN state, update login_error_message. Otherwise, could set a global error or chat_error_message.
        if app.state == .LOGIN {
            app.login_error_message = reason
        } else {
            app.chat_error_message = reason // Use chat_error_message for non-login state errors
        }
    }
    log.infof("Disconnected. Reason: %s", reason)
}


update_app :: proc(app: ^App) {
    // Clear per-frame error messages if they are meant to be transient
    // app.chat_error_message = "" // Or handle display timeout elsewhere

    switch app.state {
    case .LOGIN:
        // ... (LOGIN state logic remains the same) ...
        if app.is_connected && app.login_attempted_this_connection && app.logged_in_user == nil && app.reader.buf != nil {
            line_bytes, read_err := bufio.read_line_bytes(&app.reader)
            if read_err != nil {
                if read_err == net.EOF { disconnect_and_reset(app, "Connection lost: Server closed.") }
                else if read_err == bufio.Error.Buffer_Full { disconnect_and_reset(app, "Network error: Incomplete message.") }
                else { disconnect_and_reset(app, "Network error receiving response.") }
            } else if len(line_bytes) > 0 {
                var base_resp: protocol.BaseMessage
                json_err := json.unmarshal(line_bytes, &base_resp)
                if json_err != nil { app.login_error_message = "Error: Invalid server response." }
                else {
                    switch base_resp.type {
                    case .S2C_LOGIN_SUCCESS:
                        var success_msg: protocol.S2C_Login_Success_Message
                        if json.unmarshal(line_bytes, &success_msg) == nil {
                            app.logged_in_user = new(types.User); app.logged_in_user^ = success_msg.user
                            app.login_error_message = "Login Successful! Joining 'general' channel..."
                            log.infof("Login successful: User %s (ID: %d)", app.logged_in_user.username, app.logged_in_user.id)
                            app.state = .MAIN_CHAT
                            app.username_buffer = {}; app.password_buffer = {}
                            join_req := protocol.create_c2s_join_channel_message("general")
                            join_json_bytes, marshal_err := json.marshal(join_req)
                            if marshal_err != nil {
                                log.errorf("Failed to marshal C2S_JOIN_CHANNEL for 'general': %v", marshal_err)
                                app.chat_error_message = "Error: Could not prepare join request."
                            } else {
                                final_join_payload := make([]u8, len(join_json_bytes) + 1)
                                copy(final_join_payload, join_json_bytes)
                                final_join_payload[len(join_json_bytes)] = '\n'
                                if _, write_err := net.write_all(app.conn, final_join_payload); write_err != nil {
                                    log.errorf("Failed to send C2S_JOIN_CHANNEL for 'general': %v", write_err)
                                    disconnect_and_reset(app, "Error: Failed to send join channel request.")
                                    app.state = .LOGIN
                                } else {
                                    log.info("Sent C2S_JOIN_CHANNEL for 'general' channel.")
                                }
                            }
                        } else { app.login_error_message = "Error: Malformed login success." }
                    case .S2C_LOGIN_FAILURE:
                        var failure_msg: protocol.S2C_Login_Failure_Message
                        if json.unmarshal(line_bytes, &failure_msg) == nil {
                            app.login_error_message = fmt.tprintf("Login failed: %s", failure_msg.error_message)
                        } else { app.login_error_message = "Error: Malformed login failure." }
                        app.login_attempted_this_connection = false
                    case .S2C_USER_JOINED_CHANNEL:
                        var join_msg: protocol.S2C_User_Joined_Channel_Message
                        if json.unmarshal(line_bytes, &join_msg) == nil {
                            log.infof("Received S2C_USER_JOINED_CHANNEL for '%s' during login phase.", join_msg.channel_name)
                            app.current_channel_name = join_msg.channel_name
                        }
                    case:
                        app.login_error_message = "Error: Unexpected server response during login."
                        log.warnf("Unexpected msg type %v after login attempt.", base_resp.type)
                    }
                }
            }
        }
        if app.is_connected && !app.is_connecting && !app.login_attempted_this_connection && app.logged_in_user == nil {
            username_str := cstring_buffer_to_string(app.username_buffer[:])
            if username_str == "" { disconnect_and_reset(app, "Username cannot be empty."); return }
            password_str := cstring_buffer_to_string(app.password_buffer[:])
            log.info("Preparing C2S_LOGIN...")
            login_payload := protocol.create_c2s_login_message(username_str, password_str)
            json_bytes, marshal_err := json.marshal(login_payload)
            if marshal_err != nil { disconnect_and_reset(app, "Client error: Failed to prepare login."); return }
            final_payload := make([]u8, len(json_bytes) + 1); copy(final_payload, json_bytes); final_payload[len(json_bytes)] = '\n'
            if _, write_err := net.write_all(app.conn, final_payload); write_err != nil {
                disconnect_and_reset(app, "Network error: Failed to send login.")
            } else {
                log.infof("Login message sent for %s.", username_str)
                app.login_error_message = "Login sent. Waiting for server..."
                app.login_attempted_this_connection = true
            }
        }
        else if !app.is_connected && !app.is_connecting {
            username_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) - 60, 200, 30 }
            password_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) - 20, 200, 30 }
            login_button_rect := rl.Rectangle{ (f32(app.window_width) - 200) / 2, (f32(app.window_height) / 2) + 20, 200, 40 }
            if rl.GuiTextBox(username_rect, app.username_buffer[:], &app.username_box_active) { if app.username_box_active { app.password_box_active = false } }
            if rl.GuiTextBox(password_rect, app.password_buffer[:], &app.password_box_active) { if app.password_box_active { app.username_box_active = false } }
            if rl.GuiButton(login_button_rect, "Login") {
                app.is_connecting = true; app.login_error_message = ""; app.login_attempted_this_connection = false
                log.info("Login button clicked. Connecting...")
                conn, err := net.dial("tcp", "127.0.0.1:8080")
                if err != nil { disconnect_and_reset(app, fmt.tprintf("Connection failed: %v", err)) }
                else {
                    log.info("Network connected. Initializing reader.")
                    app.is_connecting = false; app.is_connected = true; app.conn = conn
                    app.reader = bufio.make_reader(app.conn, bufio.DEFAULT_BUFFER_SIZE)
                }
            }
        }

    case .MAIN_CHAT:
        if app.conn == nil || !app.is_connected {
            log.warn("Connection lost in MAIN_CHAT. Returning to LOGIN.")
            app.state = .LOGIN; disconnect_and_reset(app, "Connection lost.")
            return
        }
        app.chat_error_message = "" // Clear previous chat error, if any, at start of update

        if app.reader.buf != nil {
            line_bytes, read_err := bufio.read_line_bytes(&app.reader)
            if read_err != nil {
                if read_err == net.EOF { disconnect_and_reset(app, "Connection lost."); app.state = .LOGIN; return }
                else if read_err == bufio.Error.Buffer_Full { disconnect_and_reset(app, "Network error: Message too large or malformed."); app.state = .LOGIN; return}
                else { disconnect_and_reset(app, fmt.tprintf("Network error: %v", read_err)); app.state = .LOGIN; return }
            }
            if len(line_bytes) > 0 {
                log.debugf("MAIN_CHAT: Received line: %s", string(line_bytes))
                var base_msg: protocol.BaseMessage
                if json.unmarshal(line_bytes, &base_msg) == nil {
                    switch base_msg.type {
                    case .S2C_NEW_MESSAGE:
                        var new_msg_data: protocol.S2C_New_Message_Message
                        if json.unmarshal(line_bytes, &new_msg_data) == nil {
                            append(&app.current_chat_messages, new_msg_data.message)
                            if len(app.current_chat_messages) > 100 { dynarray.delete_at(&app.current_chat_messages, 0) }
                            log.infof("Msg for '%s' from %d: %s", new_msg_data.message.channel_name, new_msg_data.message.author_id, new_msg_data.message.content)
                        } else { log.error("Failed to unmarshal S2C_NEW_MESSAGE.") }
                    case .S2C_USER_JOINED_CHANNEL:
                        var join_info: protocol.S2C_User_Joined_Channel_Message
                        if json.unmarshal(line_bytes, &join_info) == nil {
                            log.infof("User '%s' joined channel '%s'.", join_info.user.username, join_info.channel_name)
                            if join_info.channel_name == app.current_channel_name {
                                system_msg_text := fmt.tprintf("System: %s has joined.", join_info.user.username)
                                system_msg := types.Message{author_id=0, content=system_msg_text, channel_name=join_info.channel_name, timestamp=time.now()}
                                append(&app.current_chat_messages, system_msg)
                                if len(app.current_chat_messages) > 100 { dynarray.delete_at(&app.current_chat_messages, 0) }
                            }
                            if app.logged_in_user != nil && join_info.user.id == app.logged_in_user.id {
                                app.current_channel_name = join_info.channel_name
                            }
                        } else { log.error("Failed to unmarshal S2C_USER_JOINED_CHANNEL.")}
                    case:
                        log.warnf("MAIN_CHAT: Unhandled message type %v", base_msg.type)
                    }
                } else { log.error("MAIN_CHAT: Failed to unmarshal BaseMessage from server.") }
            }
        }

        chat_input_rect := rl.Rectangle{205, f32(app.window_height) - 45, f32(app.window_width) - 205 - 75, 40}
        send_button_rect := rl.Rectangle{f32(app.window_width) - 70, f32(app.window_height) - 45, 65, 40}
        if rl.IsMouseButtonPressed(rl.MOUSE_LEFT_BUTTON) {
            app.chat_message_box_active = rl.CheckCollisionPointRec(rl.GetMousePosition(), chat_input_rect)
        }

        enter_pressed_in_textbox := app.chat_message_box_active && (rl.IsKeyPressed(rl.KEY_ENTER) || rl.IsKeyPressed(rl.KEY_KP_ENTER))
        send_button_clicked := rl.GuiButton(send_button_rect, "Send")

        if send_button_clicked || enter_pressed_in_textbox {
            if !app.is_connected || app.conn == nil {
                log.error("Send action, but not connected.")
                app.chat_error_message = "Not connected to server."
            } else {
                message_content := cstring_buffer_to_string(app.chat_message_buffer[:])
                trimmed_content := strings.trim_space(message_content)

                if trimmed_content == "" {
                    log.debug("Send action, but message is empty.")
                    // Optionally provide UI feedback that message is empty
                } else {
                    send_payload := protocol.create_c2s_send_message_message(trimmed_content, "")
                    json_bytes, marshal_err := json.marshal(send_payload)
                    if marshal_err != nil {
                        log.errorf("Failed to marshal C2S_SEND_MESSAGE: %v", marshal_err)
                        app.chat_error_message = "Error: Could not prepare message."
                    } else {
                        final_payload := make([]u8, len(json_bytes) + 1)
                        copy(final_payload, json_bytes)
                        final_payload[len(json_bytes)] = '\n'

                        bytes_written, write_err := net.write_all(app.conn, final_payload)
                        if write_err != nil {
                            log.errorf("Failed to send C2S_SEND_MESSAGE: %v. Bytes written: %d", write_err, bytes_written)
                            disconnect_and_reset(app, "Error: Message send failed.")
                            app.state = .LOGIN // Revert to login on send failure
                        } else {
                            log.infof("Sent message: %s", trimmed_content)
                            app.chat_message_buffer = {} // Clear buffer
                            // app.chat_message_box_active = true; // Keep focus, usually good UX
                        }
                    }
                }
            }
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
        else if app.is_connected && !app.login_attempted_this_connection { button_text = "Send Credentials" }
        rl.GuiTextBox(username_rect, app.username_buffer[:], &app.username_box_active)
        rl.GuiTextBox(password_rect, app.password_buffer[:], &app.password_box_active)
        rl.GuiButton(login_button_rect, button_text) // Store result if needed for click sound etc.
        status_text_y := login_button_rect.y + login_button_rect.height + 20
        current_status_message := ""; status_color := rl.GRAY
        if app.login_error_message != "" {
            current_status_message = app.login_error_message
            if strings.contains(strings.to_lower(app.login_error_message), "failed") ||
               strings.contains(strings.to_lower(app.login_error_message), "error") { status_color = rl.RED }
            else if strings.contains(strings.to_lower(app.login_error_message), "success") { status_color = rl.GREEN }
            else if strings.contains(app.login_error_message, "Waiting") || strings.contains(app.login_error_message, "sent") { status_color = rl.ORANGE }
            else { status_color = rl.BLACK }
        } else if app.is_connecting { current_status_message = "Connecting..."; status_color = rl.ORANGE }
        else if app.is_connected && app.login_attempted_this_connection && app.logged_in_user == nil { current_status_message = "Login sent. Waiting..."; status_color = rl.SKYBLUE }
        else if app.is_connected { current_status_message = "Connected. Ready to login."; status_color = rl.GREEN }
        else { current_status_message = "Please enter credentials." }
        text_width := rl.MeasureText(current_status_message, 20)
        rl.DrawText(current_status_message, (app.window_width - text_width)/2, i32(status_text_y), 20, status_color)

    case .MAIN_CHAT:
        channel_list_rect := rl.Rectangle{0, 0, 200, f32(app.window_height)}
        message_view_rect := rl.Rectangle{200, 0, f32(app.window_width) - 400, f32(app.window_height) - 50}
        user_list_rect := rl.Rectangle{f32(app.window_width) - 200, 0, 200, f32(app.window_height)}
        chat_input_rect := rl.Rectangle{205, f32(app.window_height) - 45, f32(app.window_width) - 205 - 75, 40}
        send_button_rect := rl.Rectangle{f32(app.window_width) - 70, f32(app.window_height) - 45, 65, 40}

        rl.DrawRectangleRec(channel_list_rect, rl.Fade(rl.BLUE, 0.1))
        rl.DrawText("Channels", 10, 10, 20, rl.DARKGRAY)
        channel_display_name := app.current_channel_name if app.current_channel_name != "" else "None"
        rl.DrawText(fmt.tprintf("# %s", channel_display_name), 15, 40, 18, rl.BLUE)
        if app.logged_in_user != nil {
             rl.DrawText(fmt.tprintf("User: %s", app.logged_in_user.username), 10, app.window_height - 25, 16, rl.DARKGRAY)
        }

        rl.DrawRectangleRec(user_list_rect, rl.Fade(rl.GREEN, 0.1))
        rl.DrawText("Users", app.window_width - 190, 10, 20, rl.DARKGRAY)

        rl.DrawRectangleRec(message_view_rect, rl.Fade(rl.GRAY, 0.05))
        message_font_size := 18; line_height := 20
        msg_padding_x := i32(message_view_rect.x + 10)
        current_draw_y := i32(message_view_rect.y + message_view_rect.height) - line_height - 5

        if len(app.current_chat_messages) == 0 {
            no_msg_text := fmt.tprintf("No messages yet in #%s. Say hi!", channel_display_name)
            text_w := rl.MeasureText(no_msg_text, message_font_size)
            rl.DrawText(no_msg_text, i32(message_view_rect.x + (message_view_rect.width - f32(text_w))/2), i32(message_view_rect.y + 20), message_font_size, rl.GRAY)
        } else {
            for i := len(app.current_chat_messages) - 1; i >= 0; i -= 1 {
                message := app.current_chat_messages[i]
                author_name_str: string; author_color := rl.DARKGRAY
                if app.logged_in_user != nil && message.author_id == app.logged_in_user.id { author_name_str = "You"; author_color = rl.SKYBLUE }
                else if message.author_id == 0 { author_name_str = "System"; author_color = rl.PURPLE }
                else { author_name_str = fmt.tprintf("User_%v", message.author_id) }
                author_prefix := fmt.tprintf("%s: ", author_name_str)
                author_text_width := rl.MeasureText(author_prefix, message_font_size)
                rl.DrawText(author_prefix, msg_padding_x, current_draw_y, message_font_size, author_color)
                rl.DrawText(message.content, msg_padding_x + author_text_width, current_draw_y, message_font_size, rl.BLACK)
                current_draw_y -= line_height
                if current_draw_y < i32(message_view_rect.y) { break }
            }
        }

        // Display chat-specific error messages at the top of message view or bottom
        if app.chat_error_message != "" {
            error_text_width := rl.MeasureText(app.chat_error_message, 16)
            rl.DrawText(app.chat_error_message, i32(message_view_rect.x + (message_view_rect.width - f32(error_text_width))/2), i32(message_view_rect.y + 5), 16, rl.RED)
        }


        if rl.GuiTextBox(chat_input_rect, app.chat_message_buffer[:], &app.chat_message_box_active) {
            // If enter pressed, it's handled in update_app. This call is mainly for drawing and direct mouse interaction.
        }
        // The GuiButton for "Send" is drawn here, but its click is handled in update_app
        rl.GuiButton(send_button_rect, "Send")

    }
}

cleanup_app :: proc(app: ^App) {
    if app.conn != nil { log.info("Closing network connection."); net.close(app.conn); app.conn = nil; app.is_connected = false }
    if app.logged_in_user != nil { free(app.logged_in_user); app.logged_in_user = nil }

    log.info("Application cleanup finished.")
}
