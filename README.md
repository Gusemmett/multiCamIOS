# multiCam

multiCam is a proof-of-concept iOS application that records **simultaneous multi-camera video** while communicating with a companion Python controller over the local network.  The repo contains:

* `multiCam/` – the Swift app targeting iOS 17+
* `pythonController/` – a lightweight Python CLI used for development/testing that sends commands to the iOS app
* `multiCam_API.yaml` – OpenAPI 3.1 specification describing the network protocol

## Prerequisites

| Component | Version |
|-----------|---------|
| Xcode     | 15 or newer |
| iOS SDK   | 15.0 | 
| Python    | 3.10+ (for `pythonController`) |

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/YOUR_USERNAME/multiCam.git
cd multiCam
```

### 2. Run the iOS application

1. Open `multiCam.xcodeproj` in Xcode.
2. Select an iOS 15 (or later) device
3. Build & run (`⌘R`).

### 3. Use the Python controller (optional)

The Python tool is managed with **pixi**, a fast cross-platform package manager.

```bash
cd pythonController
pixi run python testNetworkCommands.py  # sends sample commands to the app
```

If you do not have pixi installed, follow the instructions at <https://prefix.dev/pixi> or just create a virtualenv and install the dependencies listed in `pixi.lock`.

## Network Protocol

A full description of the control protocol lives in [`multiCam_API.yaml`](multiCam_API.yaml).  You can render it with any OpenAPI viewer such as **Swagger UI**:

```bash
npm install -g http-server
http-server .
# then open http://localhost:8080/swagger-ui/?url=multiCam_API.yaml
```

## Project Structure

```
.
├── multiCam                # Swift sources
│   ├── CameraManager.swift
│   ├── CameraPreviewView.swift
│   ├── NetworkManager.swift
│   └── …
├── pythonController        # CLI test utilities (pixi-managed)
└── multiCam_API.yaml       # OpenAPI spec
```
