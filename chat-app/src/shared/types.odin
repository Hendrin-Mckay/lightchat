package shared

import "core:time"

User :: struct {
    id:       u64,
    username: string,
    email:    string,
    status:   UserStatus,
    avatar:   string,
}

UserStatus :: enum {
    ONLINE,
    AWAY,
    BUSY,
    OFFLINE,
}

Server :: struct {
    id:       u64,
    name:     string,
    owner_id: u64,
    channels: [dynamic]Channel,
}

Channel :: struct {
    id:        u64,
    name:      string,
    server_id: u64,
    messages:  [dynamic]Message,
}

Message :: struct {
    id:         u64,
    author_id:  u64,
    channel_id: u64,
    content:    string,
    image_path: string,  // For image attachments
    timestamp:  time.Time,
    edited:     bool,
}
