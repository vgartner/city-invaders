extends SceneTree
# Read the engine's native debugger profiler using Godot's own Variant codec.
var server := TCPServer.new()
var stream: StreamPeerTCP
var packet := PacketPeerStream.new()
var log_file: FileAccess
var thread_id := 0
var started := false
var last_control := ""
var counters := {}
var output_path := "/tmp/city-invaders-profile.jsonl"
var control_path := "/tmp/city-invaders-profile.control"
var port := 6008
var control_cd := 0.0
func _initialize():
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with("--output="): output_path = arg.trim_prefix("--output=")
        elif arg.begins_with("--control="): control_path = arg.trim_prefix("--control=")
        elif arg.begins_with("--port="): port = int(arg.trim_prefix("--port="))
    log_file = FileAccess.open(output_path, FileAccess.WRITE)
    if log_file == null:
        push_error("Cannot open profiler output: " + output_path)
        quit(1)
        return
    var error := server.listen(port, "127.0.0.1")
    if error != OK:
        push_error("Profiler listen failed: " + error_string(error))
        quit(1)
        return
    print("Profiler capture ready on 127.0.0.1:", port)
func send_command(method: String, data: Array):
    packet.put_var([method, thread_id, data])
func _process(delta):
    control_cd -= delta
    if control_cd <= 0:
        control_cd = 0.1
        if FileAccess.file_exists(control_path) and FileAccess.get_file_as_string(control_path).strip_edges() == "quit":
            if stream != null:
                send_command("profiler:servers", [false])
                send_command("profiler:visual", [false])
            log_file.flush()
            quit()
            return false
    if stream == null:
        if server.is_connection_available():
            stream = server.take_connection()
            packet.stream_peer = stream
            packet.input_buffer_max_size = 67108864 # Resource inventories can exceed the 64 KiB default.
            packet.output_buffer_max_size = 8388608
            print("Debugger connected")
        return false
    stream.poll()
    while packet.get_available_packet_count() > 0:
        var message = packet.get_var(false)
        if not message is Array or message.size() != 3:
            continue
        var method: String = str(message[0])
        thread_id = int(message[1]) if thread_id == 0 else thread_id
        counters[method] = counters.get(method, 0) + 1
        if method == "debug_enter":
            packet.put_var(["continue", int(message[1]), []])
        if method in ["servers:function_signature", "servers:profile_frame", "servers:profile_total", "visual:profile_frame", "servers:memory_usage", "error"]:
            log_file.store_line(JSON.stringify({"capture_us":Time.get_ticks_usec(),"method":method,"data":message[2]}))
        if method == "servers:memory_usage":
            log_file.flush()
        if not started:
            started = true
            print("Debugger handshake received: ", method, " thread=", thread_id)
    var control := ""
    if FileAccess.file_exists(control_path):
        control = FileAccess.get_file_as_string(control_path).strip_edges()
    if started and control != last_control:
        last_control = control
        if control == "memory":
            send_command("servers:memory", [])
        elif control == "visual_start":
            send_command("profiler:visual", [true])
        elif control == "visual_stop":
            send_command("profiler:visual", [false])
        elif control.begins_with("start"):
            send_command("profiler:servers", [true, [128, true]])
            log_file.store_line(JSON.stringify({"capture_us":Time.get_ticks_usec(),"method":"capture_start","label":control}))
            print("Profiling started: ", control)
        elif control.begins_with("stop"):
            send_command("profiler:servers", [false])
            log_file.store_line(JSON.stringify({"capture_us":Time.get_ticks_usec(),"method":"capture_stop","label":control}))
            log_file.flush()
            print("Profiling stopped: ", counters)
    return false
