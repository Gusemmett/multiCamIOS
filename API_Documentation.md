# multiCam Network API Documentation

## Overview

The multiCam system enables synchronized recording across multiple iPhone devices connected via local WiFi network. The protocol uses TCP connections on port 8080 with JSON message format.

## Table of Contents

- [Discovery](#discovery)
- [Connection](#connection)
- [Commands](#commands)
  - [START_RECORDING](#start_recording)
  - [STOP_RECORDING](#stop_recording)
  - [DEVICE_STATUS](#device_status)
  - [GET_VIDEO](#get_video)
  - [HEARTBEAT](#heartbeat)
- [Response Format](#response-format)
- [File Transfer Protocol](#file-transfer-protocol)
- [Error Handling](#error-handling)
- [Examples](#examples)

## Discovery

Devices advertise themselves using Bonjour/mDNS:
- **Service Type**: `_multicam._tcp.local.`
- **Service Name**: `multiCam-{deviceId}`
- **Port**: 8080

Example discovery with Python:
```python
from zeroconf import ServiceBrowser, Zeroconf

zeroconf = Zeroconf()
browser = ServiceBrowser(zeroconf, "_multicam._tcp.local.", listener)
```

## Connection

1. **Protocol**: TCP
2. **Port**: 8080
3. **Format**: JSON messages
4. **Encoding**: UTF-8

## Commands

All commands use the same JSON structure with different `command` values:

### Base Command Structure

```json
{
  "command": "COMMAND_NAME",
  "timestamp": 1756058338.373178,
  "deviceId": "controller",
  "fileId": "optional_file_id"
}
```

### START_RECORDING

Starts camera recording on the device.

#### Request

```json
{
  "command": "START_RECORDING",
  "timestamp": 1756058341.500000,
  "deviceId": "controller"
}
```

**Fields:**
- `command`: `"START_RECORDING"`
- `timestamp`: Unix timestamp (seconds)
  - **Current time**: Start immediately
  - **Future time**: Schedule synchronized start
- `deviceId`: Controller identifier

#### Response

**Immediate Start:**
```json
{
  "deviceId": "383D6B9F-806C-48D7-ABC7-F772EDE2E15B",
  "status": "Command received",
  "timestamp": 1756058341.523456,
  "isRecording": true,
  "fileId": null,
  "fileSize": null
}
```

**Scheduled Start:**
```json
{
  "deviceId": "383D6B9F-806C-48D7-ABC7-F772EDE2E15B",
  "status": "Scheduled recording accepted",
  "timestamp": 1756058341.523456,
  "isRecording": false,
  "fileId": null,
  "fileSize": null
}
```

### STOP_RECORDING

Stops current recording session.

#### Request

```json
{
  "command": "STOP_RECORDING",
  "timestamp": 1756058360.123456,
  "deviceId": "controller"
}
```

#### Response

```json
{
  "deviceId": "383D6B9F-806C-48D7-ABC7-F772EDE2E15B",
  "status": "Recording stopped",
  "timestamp": 1756058360.234567,
  "isRecording": false,
  "fileId": "video_1756058341.500",
  "fileSize": null
}
```

**Note**: Response may be delayed until recording is fully processed and file is saved.

### DEVICE_STATUS

Requests current device status.

#### Request

```json
{
  "command": "DEVICE_STATUS",
  "timestamp": 1756058365.789012,
  "deviceId": "controller"
}
```

#### Response

```json
{
  "deviceId": "383D6B9F-806C-48D7-ABC7-F772EDE2E15B",
  "status": "Ready",
  "timestamp": 1756058365.890123,
  "isRecording": false,
  "fileId": null,
  "fileSize": null
}
```

### GET_VIDEO

Downloads a recorded video file.

#### Request

```json
{
  "command": "GET_VIDEO",
  "timestamp": 1756058370.345678,
  "deviceId": "controller",
  "fileId": "video_1756058341.500"
}
```

**Fields:**
- `fileId`: File identifier returned from STOP_RECORDING

#### Response

See [File Transfer Protocol](#file-transfer-protocol) section.

### HEARTBEAT

Keeps connection alive and checks device responsiveness.

#### Request

```json
{
  "command": "HEARTBEAT",
  "timestamp": 1756058375.901234,
  "deviceId": "controller"
}
```

#### Response

```json
{
  "deviceId": "383D6B9F-806C-48D7-ABC7-F772EDE2E15B",
  "status": "Command received",
  "timestamp": 1756058375.912345,
  "isRecording": false,
  "fileId": null,
  "fileSize": null
}
```

## Response Format

All responses use the standard format:

```json
{
  "deviceId": "string",      // Device UUID
  "status": "string",        // Human-readable status
  "timestamp": 1234567890.0, // Unix timestamp (seconds)
  "isRecording": boolean,    // Current recording state
  "fileId": "string|null",   // File ID (for STOP_RECORDING)
  "fileSize": "number|null"  // Future use
}
```

## File Transfer Protocol

The GET_VIDEO command uses a binary protocol:

### Protocol Format

1. **Header Size** (4 bytes): Big-endian uint32 containing JSON header size
2. **JSON Header**: FileResponse object with file metadata
3. **Binary Data**: Raw video file content

### FileResponse Header

```json
{
  "deviceId": "383D6B9F-806C-48D7-ABC7-F772EDE2E15B",
  "fileId": "video_1756058341.500",
  "fileName": "video_1756058341.500.mov",
  "fileSize": 47523840,
  "status": "ready"
}
```

### Python Implementation Example

```python
import struct
import json

def download_file(sock):
    # Read header size
    header_size_data = sock.recv(4)
    header_size = struct.unpack('>I', header_size_data)[0]
    
    # Read JSON header
    header_data = sock.recv(header_size)
    header = json.loads(header_data.decode('utf-8'))
    
    # Read file data
    file_size = header['fileSize']
    file_data = b""
    while len(file_data) < file_size:
        chunk = sock.recv(min(8192, file_size - len(file_data)))
        file_data += chunk
    
    return header, file_data
```

## Error Handling

### Error Response Format

Errors use the standard response format with error status:

```json
{
  "deviceId": "383D6B9F-806C-48D7-ABC7-F772EDE2E15B",
  "status": "File not found",
  "timestamp": 1756058370.456789,
  "isRecording": false,
  "fileId": null,
  "fileSize": null
}
```

### Common Error Messages

| Error | Description | Cause |
|-------|-------------|-------|
| `"File not found"` | Requested file doesn't exist | Invalid fileId in GET_VIDEO |
| `"Invalid command format"` | JSON parsing error | Malformed request |
| `"Device not ready"` | Camera not initialized | Camera permission denied |
| `"Recording already in progress"` | Duplicate start command | Multiple START_RECORDING calls |
| `"No recording in progress"` | Stop without start | STOP_RECORDING when not recording |

## Examples

### Complete Recording Workflow

```python
import socket
import json
import time

# 1. Connect to device
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect(('192.168.1.100', 8080))

# 2. Start synchronized recording (3 seconds in future)
start_time = time.time() + 3.0
start_cmd = {
    "command": "START_RECORDING",
    "timestamp": start_time,
    "deviceId": "controller"
}
sock.send(json.dumps(start_cmd).encode('utf-8'))
response = json.loads(sock.recv(1024).decode('utf-8'))
print(f"Start response: {response}")

# 3. Wait for recording...
time.sleep(10)

# 4. Stop recording
stop_cmd = {
    "command": "STOP_RECORDING",
    "timestamp": time.time(),
    "deviceId": "controller"
}
sock.send(json.dumps(stop_cmd).encode('utf-8'))
response = json.loads(sock.recv(1024).decode('utf-8'))
file_id = response.get('fileId')
print(f"Stop response: {response}")

# 5. Download video file
if file_id:
    get_cmd = {
        "command": "GET_VIDEO",
        "timestamp": time.time(),
        "deviceId": "controller",
        "fileId": file_id
    }
    sock.send(json.dumps(get_cmd).encode('utf-8'))
    
    # Handle binary file download
    header, file_data = download_file(sock)
    with open(f"{file_id}.mov", 'wb') as f:
        f.write(file_data)
    print(f"Downloaded: {header['fileName']}")

sock.close()
```

### Multi-Device Synchronization

```python
devices = [
    ('192.168.1.100', 8080),
    ('192.168.1.101', 8080),
    ('192.168.1.102', 8080)
]

# Calculate synchronized start time
sync_start = time.time() + 5.0

# Send start command to all devices simultaneously
for ip, port in devices:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((ip, port))
    
    cmd = {
        "command": "START_RECORDING",
        "timestamp": sync_start,
        "deviceId": "controller"
    }
    
    sock.send(json.dumps(cmd).encode('utf-8'))
    response = json.loads(sock.recv(1024).decode('utf-8'))
    print(f"Device {ip}: {response['status']}")
    
    sock.close()
```

## Network Requirements

### Firewall Settings
- **Port 8080**: Must be open for TCP connections
- **Multicast**: Required for Bonjour/mDNS discovery

### iOS Permissions Required
- `NSLocalNetworkUsageDescription`: Local network access
- `NSBonjourServices`: Service discovery
- Network entitlements: `com.apple.security.network.server`

### Performance Considerations
- **Latency**: < 100ms for good synchronization
- **Bandwidth**: ~50MB per minute of 1080p video
- **Concurrent Connections**: 1 controller to many devices
- **Timeout**: 30 seconds for file downloads

---

*Generated for multiCam v1.0.0*