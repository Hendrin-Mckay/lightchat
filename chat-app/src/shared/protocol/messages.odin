package protocol

import "core:time"

MessageType :: enum {
    USER_JOIN,
    USER_LEAVE,
    CHAT_MESSAGE,
    IMAGE_MESSAGE,
    CHANNEL_JOIN,
    CHANNEL_LEAVE,
    USER_STATUS_UPDATE,
}

NetworkMessage :: struct {
    type:      MessageType,
    sender_id: u64,
    data:      []u8,
    timestamp: time.Time,
}
