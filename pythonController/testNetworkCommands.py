#!/usr/bin/env python3

import socket
import json
import time
import threading
import struct
import os
import glob
from zeroconf import ServiceBrowser, Zeroconf
import argparse
import ffmpeg

class MultiCamController:
    def __init__(self):
        self.discovered_devices = {}
        self.zeroconf = Zeroconf()
        self.browser = None
        self.last_downloaded_files = []
        self.debug = False
        
    def discover_devices(self, timeout=5):
        """Discover multiCam devices on the network using Bonjour/mDNS"""
        print(f"🔍 Discovering multiCam devices for {timeout} seconds...")
        
        class MultiCamListener:
            def __init__(self, controller):
                self.controller = controller
                
            def remove_service(self, zeroconf, type, name):
                print(f"❌ Service removed: {name}")
                if name in self.controller.discovered_devices:
                    del self.controller.discovered_devices[name]
                    
            def add_service(self, zeroconf, type, name):
                info = zeroconf.get_service_info(type, name)
                if info:
                    ip = socket.inet_ntoa(info.addresses[0])
                    port = info.port
                    print(f"✅ Found multiCam device: {name} at {ip}:{port}")
                    self.controller.discovered_devices[name] = {
                        'ip': ip,
                        'port': port,
                        'info': info
                    }
                    
            def update_service(self, zeroconf, type, name):
                pass
        
        listener = MultiCamListener(self)
        self.browser = ServiceBrowser(self.zeroconf, "_multicam._tcp.local.", listener)
        
        # Wait for discovery
        time.sleep(timeout)
        
        if self.discovered_devices:
            print(f"\n📱 Discovered {len(self.discovered_devices)} device(s):")
            for name, device in self.discovered_devices.items():
                print(f"  - {name}: {device['ip']}:{device['port']}")
        else:
            print("❌ No multiCam devices found")
            
        return list(self.discovered_devices.values())
    
    def send_command(self, device_ip, device_port, command, timestamp=None, file_id=None):
        """Send a command to a multiCam device"""
        try:
            # Create command message
            message = {
                "command": command,
                "timestamp": timestamp or time.time(),
                "deviceId": "controller"
            }
            
            if file_id:
                message["fileId"] = file_id
            
            # Convert to JSON
            json_data = json.dumps(message).encode('utf-8')
            
            # Connect and send
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(30)  # Longer timeout for file transfers
            
            if self.debug:
                print(f"📡 Connecting to {device_ip}:{device_port}...")
            sock.connect((device_ip, device_port))
            
            if self.debug:
                print(f"📤 Sending command: {command}")
                if file_id:
                    print(f"   File ID: {file_id}")
            sock.send(json_data)
            
            # Handle different response types
            if command == "GET_VIDEO":
                return self._handle_file_download(sock, device_ip, file_id)
            else:
                # Wait for JSON response - use larger buffer and handle chunked responses for LIST_FILES
                response_data = b""
                
                # For LIST_FILES, we may need to receive in chunks due to large responses
                if command == "LIST_FILES":
                    sock.settimeout(10)  # Set timeout for receiving data
                    while True:
                        try:
                            chunk = sock.recv(8192)
                            if not chunk:
                                break
                            response_data += chunk
                            # Check if we have a complete JSON response
                            try:
                                decoded = response_data.decode('utf-8')
                                json.loads(decoded)
                                break  # Complete JSON received
                            except (json.JSONDecodeError, UnicodeDecodeError):
                                continue  # Keep receiving
                        except socket.timeout:
                            break
                else:
                    response_data = sock.recv(4096)
                
                if response_data:
                    response_json = json.loads(response_data.decode('utf-8'))
                    if self.debug:
                        print(f"📥 Response: {json.dumps(response_json, indent=2)}")
                    
                    # Extract file ID from stop recording response
                    if command == "STOP_RECORDING" and "fileId" in response_json and response_json["fileId"]:
                        if self.debug:
                            print(f"📁 File ID received: {response_json['fileId']}")
                        return response_json["fileId"]
                    
                    # Return response data for further processing
                    return response_json
                
                sock.close()
                return True
            
        except Exception as e:
            print(f"❌ Error sending command to {device_ip}:{device_port}: {e}")
            return False
    
    def _handle_file_download(self, sock, device_ip, file_id):
        """Handle file download from device"""
        try:
            print(f"📥 Receiving file data...")
            
            # Read header size (4 bytes, big-endian uint32)
            header_size_data = sock.recv(4)
            if len(header_size_data) != 4:
                print("❌ Failed to read header size")
                return False
            
            header_size = struct.unpack('>I', header_size_data)[0]
            print(f"📄 Header size: {header_size} bytes")
            
            # Read header data
            header_data = b""
            while len(header_data) < header_size:
                chunk = sock.recv(header_size - len(header_data))
                if not chunk:
                    break
                header_data += chunk
            
            # Parse header JSON
            header_info = json.loads(header_data.decode('utf-8'))
            file_name = header_info["fileName"]
            file_size = header_info["fileSize"]
            
            print(f"📁 File: {file_name}")
            print(f"📊 Size: {file_size:,} bytes ({file_size / 1024 / 1024:.1f} MB)")
            
            # Create downloads directory
            downloads_dir = os.path.expanduser("~/Downloads/multiCam")
            os.makedirs(downloads_dir, exist_ok=True)
            
            # Create unique filename with device IP
            device_name = device_ip.replace('.', '_')
            local_filename = f"{device_name}_{file_name}"
            local_path = os.path.join(downloads_dir, local_filename)
            
            # Download file data
            print(f"💾 Downloading to: {local_path}")
            bytes_received = 0
            
            with open(local_path, 'wb') as f:
                while bytes_received < file_size:
                    chunk_size = min(8192, file_size - bytes_received)
                    chunk = sock.recv(chunk_size)
                    if not chunk:
                        break
                    f.write(chunk)
                    bytes_received += len(chunk)
                    
                    # Progress indicator
                    progress = (bytes_received / file_size) * 100
                    print(f"\r📊 Progress: {progress:.1f}% ({bytes_received:,}/{file_size:,} bytes)", end='')
            
            print(f"\n✅ File downloaded successfully: {local_path}")
            sock.close()
            return local_path
            
        except Exception as e:
            print(f"❌ Error downloading file: {e}")
            sock.close()
            return False
    
    def send_command_to_all(self, command, timestamp=None, sync_delay=3.0):
        """Send a command to all discovered devices"""
        if not self.discovered_devices:
            print("❌ No devices discovered. Run discovery first.")
            return
        
        # For START_RECORDING, calculate a future timestamp for synchronization
        if command == "START_RECORDING" and timestamp is None:
            sync_timestamp = time.time() + sync_delay
            print(f"📡 Broadcasting synchronized {command} to {len(self.discovered_devices)} device(s)")
            print(f"🕐 Scheduled start time: {sync_timestamp} (in {sync_delay} seconds)")
        else:
            sync_timestamp = timestamp or time.time()
            if self.debug:
                print(f"📡 Broadcasting {command} to {len(self.discovered_devices)} device(s) at timestamp {sync_timestamp}")
        
        # Send to all devices simultaneously using threads
        threads = []
        results = {}
        
        def send_and_store_result(device_name, device_ip, device_port):
            result = self.send_command(device_ip, device_port, command, sync_timestamp)
            results[device_name] = result
        
        for name, device in self.discovered_devices.items():
            thread = threading.Thread(
                target=send_and_store_result,
                args=(name, device['ip'], device['port'])
            )
            threads.append(thread)
            thread.start()
        
        # Wait for all threads to complete
        for thread in threads:
            thread.join()
        
        # Return file IDs if stopping recording
        if command == "STOP_RECORDING":
            print(f"\n🔍 Debug: Results from stop command: {results}")
            file_ids = {name: result for name, result in results.items() if isinstance(result, str)}
            if file_ids:
                print(f"\n📁 Recorded files available for download:")
                for device_name, file_id in file_ids.items():
                    print(f"  {device_name}: {file_id}")
            else:
                print(f"\n❌ No file IDs received. Results: {results}")
            return file_ids
        
        return results
    
    def list_files_on_all_devices(self):
        """List all recorded files on all devices"""
        if not self.discovered_devices:
            print("❌ No devices discovered. Run discovery first.")
            return
        
        print(f"📁 Listing files on {len(self.discovered_devices)} device(s)...\n")
        
        total_files = 0
        total_size = 0
        
        for device_name, device in self.discovered_devices.items():
            try:
                print(f"📱 {device_name} ({device['ip']}:{device['port']}):")
                response = self.send_command(device['ip'], device['port'], "LIST_FILES")
                
                if isinstance(response, dict) and 'files' in response:
                    files = response['files']
                    if files:
                        print(f"   Found {len(files)} file(s):")
                        device_total_size = 0
                        
                        for file_info in files:
                            file_size_mb = file_info['fileSize'] / (1024 * 1024)
                            device_total_size += file_info['fileSize']
                            creation_time = time.strftime('%Y-%m-%d %H:%M:%S', 
                                                        time.localtime(file_info['creationDate']))
                            
                            print(f"   • {file_info['fileName']}")
                            print(f"     ID: {file_info['fileId']}")
                            print(f"     Size: {file_size_mb:.1f} MB")
                            print(f"     Created: {creation_time}")
                            print()
                        
                        print(f"   Device total: {device_total_size / (1024 * 1024):.1f} MB")
                        total_files += len(files)
                        total_size += device_total_size
                    else:
                        print("   No files found")
                else:
                    print("   ❌ Failed to get file list")
                
                print()
                
            except Exception as e:
                print(f"   ❌ Error: {e}")
                print()
        
        if total_files > 0:
            print(f"📊 Summary: {total_files} total files, {total_size / (1024 * 1024):.1f} MB total")
        else:
            print("📊 No files found on any device")
    
    def manual_connect(self, ip, port=8080):
        """Manually connect to a device without discovery"""
        print(f"🔗 Manual connection to {ip}:{port}")
        self.discovered_devices[f"manual-{ip}"] = {
            'ip': ip,
            'port': port
        }
    
    def show_commands_help(self):
        """Display the full commands help"""
        print("\nAvailable commands:")
        print("1. discover - Discover multiCam devices")
        print("2. sync-start [delay] - Start recording synchronized (default 3s delay)")
        print("3. start - Start recording immediately (not synchronized)")
        print("4. stop - Stop recording on all devices")
        print("5. status - Get status from all devices")
        print("6. list-files - List all recorded files on all devices")
        print("7. download [device_name] [file_id] - Download video file")
        print("8. download-all - Download all files from last recording")
        print("9. stack-videos [output_name] - Stack downloaded videos vertically")
        print("10. connect <ip> [port] - Manually connect to device")
        print("11. check-sync - Check clock synchronization across devices")
        print("12. debug - Toggle debug output on/off")
        print("13. list - List discovered devices")
        print("14. quit - Exit")

    def interactive_mode(self):
        """Interactive command line interface"""
        print("\n🎬 multiCam Network Controller")
        print("=====================================")
        self.last_file_ids = {}
        
        # Show commands once at startup
        self.show_commands_help()
        first_command = True
        
        while True:
            if first_command:
                first_command = False
            else:
                print("\nEnter '?' to see command list")
            
            try:
                cmd = input("\n> ").strip().split()
                if not cmd:
                    continue
                    
                if cmd[0] == "quit" or cmd[0] == "q":
                    break
                elif cmd[0] == "?" or cmd[0] == "help":
                    self.show_commands_help()
                elif cmd[0] == "discover" or cmd[0] == "d":
                    self.discover_devices()
                elif cmd[0] == "sync-start":
                    delay = float(cmd[1]) if len(cmd) > 1 else 3.0
                    print(f"🔄 Preparing synchronized start with {delay}s delay...")
                    self.send_command_to_all("START_RECORDING", sync_delay=delay)
                elif cmd[0] == "start" or cmd[0] == "s":
                    print("⚡ Starting recording immediately (not synchronized)")
                    self.send_command_to_all("START_RECORDING", timestamp=time.time())
                elif cmd[0] == "stop":
                    result = self.send_command_to_all("STOP_RECORDING")
                    if isinstance(result, dict):
                        self.last_file_ids = result
                elif cmd[0] == "status":
                    self.send_command_to_all("DEVICE_STATUS")
                elif cmd[0] == "list-files":
                    self.list_files_on_all_devices()
                elif cmd[0] == "download":
                    if len(cmd) == 3:
                        device_name, file_id = cmd[1], cmd[2]
                        if device_name in self.discovered_devices:
                            device = self.discovered_devices[device_name]
                            self.send_command(device['ip'], device['port'], "GET_VIDEO", file_id=file_id)
                        else:
                            print(f"❌ Device '{device_name}' not found")
                    elif len(cmd) == 1 and self.last_file_ids:
                        print("Available files from last recording:")
                        for device_name, file_id in self.last_file_ids.items():
                            print(f"  {device_name}: {file_id}")
                        print("Usage: download <device_name> <file_id>")
                    else:
                        print("Usage: download <device_name> <file_id>")
                elif cmd[0] == "download-all":
                    if self.last_file_ids:
                        print(f"📥 Downloading {len(self.last_file_ids)} files...")
                        downloaded_files = []
                        for device_name, file_id in self.last_file_ids.items():
                            if device_name in self.discovered_devices:
                                device = self.discovered_devices[device_name]
                                print(f"\n📱 Downloading from {device_name}...")
                                file_path = self.send_command(device['ip'], device['port'], "GET_VIDEO", file_id=file_id)
                                if file_path:
                                    downloaded_files.append(file_path)
                        
                        if downloaded_files:
                            self.last_downloaded_files = downloaded_files
                            print(f"\n✅ Downloaded {len(downloaded_files)} files successfully")
                            print("💡 Use 'stack-videos' to combine them vertically")
                    else:
                        print("❌ No recorded files available. Stop recording first.")
                elif cmd[0] == "stack-videos":
                    output_name = cmd[1] if len(cmd) > 1 else None
                    self.stack_videos_vertically(output_name=output_name)
                elif cmd[0] == "check-sync":
                    self.check_clock_synchronization()
                elif cmd[0] == "debug":
                    self.debug = not self.debug
                    status = "enabled" if self.debug else "disabled"
                    print(f"🐛 Debug output {status}")
                elif cmd[0] == "connect" or cmd[0] == "c":
                    if len(cmd) >= 2:
                        port = int(cmd[2]) if len(cmd) > 2 else 8080
                        self.manual_connect(cmd[1], port)
                    else:
                        print("Usage: connect <ip> [port]")
                elif cmd[0] == "list" or cmd[0] == "l":
                    if self.discovered_devices:
                        print("\n📱 Connected devices:")
                        for name, device in self.discovered_devices.items():
                            print(f"  - {name}: {device['ip']}:{device['port']}")
                    else:
                        print("❌ No devices connected")
                else:
                    print("❌ Unknown command")
                    
            except KeyboardInterrupt:
                break
            except Exception as e:
                print(f"❌ Error: {e}")
    
    def check_clock_synchronization(self):
        """Check clock synchronization across all devices"""
        if not self.discovered_devices:
            print("❌ No devices discovered. Run discovery first.")
            return
        
        print(f"🕐 Checking clock synchronization across {len(self.discovered_devices)} device(s)...")
        
        # Send simultaneous status requests and measure timing
        results = {}
        controller_send_time = time.time()
        
        # Send to all devices and collect responses with timing
        for device_name, device in self.discovered_devices.items():
            try:
                # Send command and measure round-trip
                send_time = time.time()
                response = self.send_command(device['ip'], device['port'], "DEVICE_STATUS", timestamp=send_time)
                receive_time = time.time()
                
                if isinstance(response, dict) and 'timestamp' in response:
                    device_timestamp = response['timestamp']
                    round_trip_time = receive_time - send_time
                    
                    # Estimate device time by compensating for half the round-trip time
                    estimated_device_time = device_timestamp + (round_trip_time / 2)
                    time_difference = estimated_device_time - receive_time
                    
                    results[device_name] = {
                        'device_time': device_timestamp,
                        'round_trip_ms': round_trip_time * 1000,
                        'time_diff_ms': time_difference * 1000,
                        'status': 'success'
                    }
                else:
                    results[device_name] = {'status': 'failed'}
                    
            except Exception as e:
                results[device_name] = {'status': 'error', 'error': str(e)}
        
        # Display results
        print(f"\n🕐 Clock Synchronization Report:")
        print(f"{'Device':<25} {'Round Trip':<12} {'Clock Diff':<12} {'Status'}")
        print("-" * 60)
        
        max_diff = 0
        min_diff = 0
        valid_devices = 0
        
        for device_name, result in results.items():
            # Shorten device name for display
            short_name = device_name.split('.')[0].replace('multiCam-', '')[:20]
            
            if result['status'] == 'success':
                round_trip = f"{result['round_trip_ms']:.1f}ms"
                time_diff = f"{result['time_diff_ms']:+.1f}ms"
                
                print(f"{short_name:<25} {round_trip:<12} {time_diff:<12} ✅")
                
                # Track max difference for summary
                diff = abs(result['time_diff_ms'])
                max_diff = max(max_diff, diff)
                if valid_devices == 0:
                    min_diff = diff
                else:
                    min_diff = min(min_diff, diff)
                valid_devices += 1
                
            elif result['status'] == 'failed':
                print(f"{short_name:<25} {'N/A':<12} {'N/A':<12} ❌ No response")
            else:
                print(f"{short_name:<25} {'N/A':<12} {'N/A':<12} ❌ Error")
        
        # Summary and recommendations
        print(f"\n📊 Synchronization Summary:")
        if valid_devices >= 2:
            print(f"   Devices checked: {valid_devices}/{len(self.discovered_devices)}")
            print(f"   Maximum time difference: {max_diff:.1f}ms")
            print(f"   Minimum time difference: {min_diff:.1f}ms")
            
            if max_diff < 50:
                print("   ✅ Good synchronization (< 50ms difference)")
            elif max_diff < 200:
                print("   ⚠️  Moderate sync (50-200ms difference) - may affect video alignment")
            else:
                print("   ❌ Poor synchronization (> 200ms difference) - consider NTP or shorter delays")
                
        elif valid_devices == 1:
            print("   ⚠️  Only one device responded - need multiple devices to check sync")
        else:
            print("   ❌ No devices responded successfully")
            
        if valid_devices > 0:
            print(f"\n💡 Tips:")
            print(f"   • Use 'sync-start' with longer delays if sync is poor")
            print(f"   • Ensure all devices are connected to the same WiFi network")
            if max_diff > 100:
                print(f"   • Try 5GHz WiFi instead of 2.4GHz for lower latency")
                print(f"   • Move devices closer to router to reduce network jitter")
    
    def stack_videos_vertically(self, video_files=None, output_name=None):
        """Stack videos vertically using FFmpeg"""
        files_to_stack = video_files or self.last_downloaded_files
        
        if not files_to_stack:
            print("❌ No video files to stack. Download videos first with 'download-all'.")
            return
        
        if len(files_to_stack) < 2:
            print("❌ Need at least 2 video files to stack.")
            return
        
        try:
            print(f"🎬 Stacking {len(files_to_stack)} videos vertically...")
            
            # Sort files by name for consistent ordering
            files_to_stack.sort()
            
            # Generate output filename
            if not output_name:
                timestamp = int(time.time())
                output_name = f"stacked_multiCam_{timestamp}.mp4"
            
            output_path = os.path.join(os.path.expanduser("~/Downloads/multiCam"), output_name)
            
            print(f"📁 Input files:")
            for i, file_path in enumerate(files_to_stack):
                print(f"  {i+1}. {os.path.basename(file_path)}")
            
            # Create FFmpeg input streams
            input_streams = []
            for file_path in files_to_stack:
                input_streams.append(ffmpeg.input(file_path))
            
            # Create vertical stack filter
            if len(input_streams) == 2:
                stacked = ffmpeg.filter(input_streams, 'vstack')
            else:
                # For more than 2 videos, use vstack with inputs parameter
                stacked = ffmpeg.filter(input_streams, 'vstack', inputs=len(input_streams))
            
            # Output with consistent encoding
            out = ffmpeg.output(
                stacked,
                output_path,
                vcodec='libx264',
                acodec='aac',
                **{'preset': 'medium', 'crf': '23'}
            )
            
            # Run FFmpeg with overwrite
            print(f"🔄 Processing videos...")
            ffmpeg.run(out, overwrite_output=True, quiet=True)
            
            print(f"✅ Stacked video created: {output_path}")
            
            # Get file size
            file_size = os.path.getsize(output_path)
            print(f"📊 File size: {file_size / (1024*1024):.1f} MB")
            
            return output_path
            
        except ffmpeg.Error as e:
            print(f"❌ FFmpeg error: {e}")
            if hasattr(e, 'stderr') and e.stderr:
                error_msg = e.stderr.decode('utf-8')
                print(f"   Details: {error_msg}")
            return None
        except Exception as e:
            print(f"❌ Error stacking videos: {e}")
            return None
    
    def cleanup(self):
        """Clean up resources"""
        if self.browser:
            self.browser.cancel()
        self.zeroconf.close()

def main():
    parser = argparse.ArgumentParser(description='multiCam Network Controller')
    parser.add_argument('--ip', help='Manually connect to specific IP address')
    parser.add_argument('--port', type=int, default=8080, help='Port to connect to (default: 8080)')
    parser.add_argument('--command', choices=['START_RECORDING', 'STOP_RECORDING', 'DEVICE_STATUS'], 
                       help='Send a single command and exit')
    parser.add_argument('--discover-only', action='store_true', help='Only discover devices and exit')
    
    args = parser.parse_args()
    
    controller = MultiCamController()
    
    try:
        if args.ip:
            # Manual connection mode
            controller.manual_connect(args.ip, args.port)
            if args.command:
                controller.send_command_to_all(args.command)
            elif not args.discover_only:
                controller.interactive_mode()
        elif args.discover_only:
            # Discovery only mode
            controller.discover_devices()
        elif args.command:
            # Discover and send command mode
            controller.discover_devices()
            controller.send_command_to_all(args.command)
        else:
            # Full interactive mode
            controller.discover_devices()
            controller.interactive_mode()
            
    except KeyboardInterrupt:
        print("\n\n👋 Goodbye!")
    finally:
        controller.cleanup()

if __name__ == "__main__":
    main()