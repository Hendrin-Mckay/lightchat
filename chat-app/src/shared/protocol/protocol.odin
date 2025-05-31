package protocol

import "core:time"
import "../types" // Adjust path as needed based on actual file structure

// MessageType defines the type of a message exchanged between client and server.
MessageType :: enum {
    // Client to Server
    C2S_LOGIN,
    C2S_SEND_MESSAGE,
    C2S_JOIN_CHANNEL, // Example: Client requests to join a channel
    C2S_CREATE_CHANNEL, // Example: Client requests to create a new channel
    C2S_REGISTER_USER,

    // Server to Client
    S2C_LOGIN_SUCCESS,
    S2C_REGISTRATION_SUCCESS,
    S2C_REGISTRATION_FAILURE,
    S2C_LOGIN_FAILURE,
    S2C_NEW_MESSAGE,
    S2C_USER_JOINED_CHANNEL, // Example: Server notifies clients that a user joined
    S2C_USER_LEFT_CHANNEL,   // Example: Server notifies clients that a user left a channel
    S2C_CHANNEL_CREATED, // Example: Server notifies clients that a channel was created
    S2C_MESSAGE_HISTORY, // Sent to a client after joining a channel
    S2C_ERROR, // Generic error message from server
}

// BaseMessage is a wrapper for all messages, containing the type.
// Specific message structs can be included in a union or handled based on type.
BaseMessage :: struct {
    type: MessageType,
}

// C2S_Login_Message is sent by the client to log in.
C2S_Login_Message :: struct {
    using base: BaseMessage, // Should be C2S_LOGIN
    username:   string,
    password:   string, // Note: Passwords should be hashed in a real application
}

// S2C_Login_Success_Message is sent by the server on successful login.
S2C_Login_Success_Message :: struct {
    using base: BaseMessage, // Should be S2C_LOGIN_SUCCESS
    user:       types.User,
    servers:    [dynamic]types.Server, // List of servers the user is part of
}

// S2C_Login_Failure_Message is sent by the server on failed login.
S2C_Login_Failure_Message :: struct {
    using base: BaseMessage, // Should be S2C_LOGIN_FAILURE
    error_message: string,
}

// C2S_Send_Message_Message is sent by the client to send a message to a channel.

// The channel is implicit from the user's session.
C2S_Send_Message_Message :: struct {
    using base: BaseMessage, // Should be C2S_SEND_MESSAGE

    content:    string,
    image_path: string, // Optional: path to an image if attached
}

// S2C_New_Message_Message is broadcast by the server when a new message is posted.
S2C_New_Message_Message :: struct {
    using base: BaseMessage, // Should be S2C_NEW_MESSAGE
    message:    types.Message,
}

// C2S_Join_Channel_Message is sent by the client to join a specific channel.
C2S_Join_Channel_Message :: struct {
    using base: BaseMessage, // Should be C2S_JOIN_CHANNEL

    channel_name: string,

}

// S2C_User_Joined_Channel_Message is sent by the server to notify clients in a channel about a new user.
S2C_User_Joined_Channel_Message :: struct {

    using base: BaseMessage,     // Should be S2C_USER_JOINED_CHANNEL
    channel_name: string,
    user:         types.User,    // The user who joined

}

// C2S_Create_Channel_Message allows a client to request the creation of a new channel on a server.
C2S_Create_Channel_Message :: struct {

    using base: BaseMessage,

    server_id:  u64,
    name:       string,
}

// S2C_Channel_Created_Message is sent by the server to notify relevant clients that a new channel has been created.
S2C_Channel_Created_Message :: struct {

    using base: BaseMessage,

    channel:    types.Channel,
}

// S2C_Error_Message is a generic error message sent by the server.
S2C_Error_Message :: struct {

    using base: BaseMessage,
    error_message: string,
    original_request_type: MessageType,

}

// C2S_Register_User_Message is sent by the client to register a new account.
C2S_Register_User_Message :: struct {
    using base: BaseMessage, // Should be C2S_REGISTER_USER
    username:   string,
    email:      string,
    password:   string,
}

// S2C_Registration_Success_Message is sent by the server on successful registration.
S2C_Registration_Success_Message :: struct {
    using base: BaseMessage, // Should be S2C_REGISTRATION_SUCCESS
    user_id:    u64,
    username:   string,
    // Consider including the full types.User if the client needs more info immediately
}

// S2C_Registration_Failure_Message is sent by the server on failed registration.
S2C_Registration_Failure_Message :: struct {
    using base: BaseMessage, // Should be S2C_REGISTRATION_FAILURE
    error_message: string,
}

// S2C_Message_History_Message is sent to a client after joining a channel, containing recent messages.
S2C_Message_History_Message :: struct {
    using base: BaseMessage, // Should be S2C_MESSAGE_HISTORY
    channel_name: string,
    messages: [dynamic]types.Message,
}

// S2C_User_Left_Channel_Message is sent by the server to notify clients in a channel about a user leaving.
S2C_User_Left_Channel_Message :: struct {
    using base: BaseMessage, // Should be S2C_USER_LEFT_CHANNEL
    user_id:      u64,       // ID of the user who left
    username:     string,    // Username of the user who left
    channel_name: string,    // Name of the channel the user left
}

// Helper procedure to create a C2S_Login_Message
create_c2s_login_message :: proc(username, password: string) -> C2S_Login_Message {
    return C2S_Login_Message{
        base = BaseMessage{type = .C2S_LOGIN},
        username = username,
        password = password,
    };
}

// Helper procedure to create a C2S_Send_Message_Message

create_c2s_send_message_message :: proc(content: string, image_path: string = "") -> C2S_Send_Message_Message {
    return C2S_Send_Message_Message{
        base = BaseMessage{type = .C2S_SEND_MESSAGE},

        content = content,
        image_path = image_path,
    };
}

// Helper for C2S_Join_Channel_Message
create_c2s_join_channel_message :: proc(channel_name: string) -> C2S_Join_Channel_Message {
    return C2S_Join_Channel_Message{
        base = BaseMessage{type = .C2S_JOIN_CHANNEL},
        channel_name = channel_name,
    };
}

// Helper procedure to create a C2S_Register_User_Message
create_c2s_register_user_message :: proc(username, email, password: string) -> C2S_Register_User_Message {
    return C2S_Register_User_Message{
        base = BaseMessage{type = .C2S_REGISTER_USER},
        username = username,
        email = email,
        password = password,
    };
}

// Helper procedure to create an S2C_Registration_Success_Message
create_s2c_registration_success_message :: proc(user_id: u64, username: string) -> S2C_Registration_Success_Message {
    return S2C_Registration_Success_Message{
        base = BaseMessage{type = .S2C_REGISTRATION_SUCCESS},
        user_id = user_id,
        username = username,
    };
}

// Helper procedure to create an S2C_Registration_Failure_Message
create_s2c_registration_failure_message :: proc(error_message: string) -> S2C_Registration_Failure_Message {
    return S2C_Registration_Failure_Message{
        base = BaseMessage{type = .S2C_REGISTRATION_FAILURE},
        error_message = error_message,
    };
}

// Helper procedure to create an S2C_Message_History_Message
create_s2c_message_history_message :: proc(channel_name: string, messages: [dynamic]types.Message) -> S2C_Message_History_Message {
    return S2C_Message_History_Message{
        base = BaseMessage{type = .S2C_MESSAGE_HISTORY},
        channel_name = channel_name,
        messages = messages,
    };
}

// Helper procedure to create an S2C_User_Left_Channel_Message
create_s2c_user_left_channel_message :: proc(user_id: u64, username: string, channel_name: string) -> S2C_User_Left_Channel_Message {
    return S2C_User_Left_Channel_Message{
        base = BaseMessage{type = .S2C_USER_LEFT_CHANNEL},
        user_id = user_id,
        username = username,
        channel_name = channel_name,
    };
}
