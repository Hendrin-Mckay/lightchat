package database

import "core:os"
import "core:fmt"
import "core:strings"
import "core:bufio" // For future use, or if more complex line-by-line reading is needed
import "core:strconv" // For string to int/enum conversion

// Assuming types.odin is in ../../shared relative to this file (src/server/database/storage.odin)
import shared "../../shared"

Database :: struct {
    users_file:    string,
    // servers_file:  string, // For future use
    // messages_file: string, // For future use
    // images_dir:    string, // For future use
}

// Helper to convert UserStatus enum to string
user_status_to_string :: proc(status: shared.UserStatus) -> string {
    switch status {
    case .ONLINE:  return "ONLINE"
    case .AWAY:    return "AWAY"
    case .BUSY:    return "BUSY"
    case .OFFLINE: return "OFFLINE"
    }
    return "OFFLINE" // Default
}

// Helper to convert string to UserStatus enum
string_to_user_status :: proc(s: string) -> shared.UserStatus {
    switch strings.to_upper(s) { // Case-insensitive matching
    case "ONLINE":  return .ONLINE
    case "AWAY":    return .AWAY
    case "BUSY":    return .BUSY
    case "OFFLINE": return .OFFLINE
    }
    return .OFFLINE // Default if string is unrecognized
}

// save_user appends a user to the users_file.
// Format: id:username:email:status_string:avatar_path

save_user :: proc(db: ^Database, user: ^shared.User) -> bool {
    if db == nil || user == nil {
        fmt.eprintln("save_user: nil database or user")
        return false
    }
    if db.users_file == "" {
        fmt.eprintln("save_user: users_file path is not set in Database struct")
        return false
    }

    // Ensure avatar string doesn't contain the delimiter ':'
    // This is a simplification; real CSV/structured formats handle this better.
    safe_username := strings.replace_all(user.username, ":", "_")
    safe_email := strings.replace_all(user.email, ":", "_")
    safe_avatar := strings.replace_all(user.avatar, ":", "_")

    user_line := fmt.tprintf("%v:%s:%s:%s:%s\n", // Added newline character
        user.id,
        safe_username,
        safe_email,
        user_status_to_string(user.status),
        safe_avatar,
    )

    err := os.write_string_to_file(db.users_file, user_line, os.FileMode.APPEND)
    if err != nil {
        fmt.eprintf("Error saving user %v to file %s: %v\n", user.id, db.users_file, err)
        return false
    }
    // fmt.printf("User %v saved to %s\n", user.id, db.users_file)
    return true
}

// load_users reads all users from the users_file.
load_users :: proc(db: ^Database) -> (users: [dynamic]shared.User, err: os.Errno) {
    if db == nil {
        fmt.eprintln("load_users: nil database")
        return nil, .EINVAL // Invalid argument
    }
    if db.users_file == "" {
        fmt.eprintln("load_users: users_file path is not set")
        return nil, .EINVAL
    }

    file_content, read_err := os.read_entire_file_from_filename(db.users_file)
    if read_err != nil {
        if read_err == .ENOENT { // File not found is okay, means no users yet
            // fmt.println("Users file not found, returning empty list.")
            return make([dynamic]shared.User), nil
        }
        fmt.eprintf("Error reading users file %s: %v\n", db.users_file, read_err)
        return nil, read_err
    }
    defer delete(file_content) // Clean up memory from read_entire_file_from_filename

    content_str := string(file_content)
    lines := strings.split_lines(content_str)

    loaded_users := make([dynamic]shared.User, 0, len(lines))

    for line in lines {
        if strings.trim_space(line) == "" { // Skip empty lines
            continue
        }
        parts := strings.split(line, ":")
        if len(parts) < 5 { // id:username:email:status:avatar
            fmt.eprintf("Skipping malformed line in users file: %s\n", line)
            continue
        }

        id, id_err := strconv.parse_u64(parts[0], 10)
        if id_err != nil {
            fmt.eprintf("Skipping user with invalid ID '%s': %v\n", parts[0], id_err)
            continue
        }

        // Restore original strings if they were replaced (not done here, assumes they were safe)
        username := parts[1]
        email    := parts[2]
        status   := string_to_user_status(parts[3])
        avatar   := parts[4]
        // If more parts exist due to ':' in avatar, join them back. This is a simple approach.
        if len(parts) > 5 {
            avatar = strings.join(parts[4:], ":")
        }


        user := shared.User{
            id       = id,
            username = username,
            email    = email,
            status   = status,
            avatar   = avatar,
        }
        append(&loaded_users, user)
    }

    // fmt.printf("Loaded %v users from %s\n", len(loaded_users), db.users_file)
    return loaded_users, nil
}

// TODO: Implement similar functions for servers and messages
// save_message :: proc(db: ^Database, message: ^shared.Message) -> bool
// load_messages :: proc(db: ^Database, channel_id: u64) -> [dynamic]shared.Message
