#!/bin/bash

# Build script for MonitorClient
echo "Building MonitorClient..."

# Clean previous builds
xcodebuild clean -project MonitorClient.xcodeproj -scheme MonitorClient

# Build for Release
xcodebuild build -project MonitorClient.xcodeproj -scheme MonitorClient -configuration Release

# Check if build was successful
if [ $? -eq 0 ]; then
    echo "Build successful!"
    echo "App location: $(pwd)/build/Release/MonitorClient.app"
    
    # Copy to Applications for testing
    cp -R build/Release/MonitorClient.app /Applications/
    echo "App copied to /Applications/"
    
    # Open Organizer
    open -a Xcode
    echo "Opening Xcode Organizer..."
else
    echo "Build failed!"
    exit 1
fi 