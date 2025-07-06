#!/bin/bash

# MonitorClient Build and Sign Script
# Builds the app, signs it with your developer certificate, and creates a signed package

set -e

# Configuration
APP_NAME="MonitorClient"
BUNDLE_ID="com.airentech.MonitorClient"
VERSION="1.0"
BUILD_DIR="build"
PACKAGE_DIR="package"
SIGNING_IDENTITY=""
TEAM_ID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    if ! command_exists xcodebuild; then
        print_error "Xcode command line tools not found. Please install Xcode or Xcode command line tools."
        exit 1
    fi
    
    if ! command_exists security; then
        print_error "security command not found. This should be available on macOS."
        exit 1
    fi
    
    if ! command_exists codesign; then
        print_error "codesign command not found. This should be available with Xcode."
        exit 1
    fi
    
    print_success "All prerequisites found"
}

# List available signing identities
list_signing_identities() {
    print_status "Available signing identities:"
    security find-identity -v -p codesigning
}

# Auto-detect signing identity
auto_detect_signing_identity() {
    print_status "Auto-detecting signing identity..."
    
    # Try to find a valid signing identity for apps
    local app_identity=$(security find-identity -v -p codesigning | grep -E "Developer ID Application|Apple Development" | head -1 | cut -d'"' -f2)
    
    if [ -n "$app_identity" ]; then
        SIGNING_IDENTITY="$app_identity"
        print_success "Auto-detected app signing identity: $SIGNING_IDENTITY"
    else
        print_warning "No app signing identity found. You may need to:"
        echo "  1. Join Apple Developer Program"
        echo "  2. Create a Developer ID certificate"
        echo "  3. Install the certificate in Keychain Access"
        echo ""
        print_status "Available identities:"
        list_signing_identities
        echo ""
        read -p "Enter signing identity (or press Enter to skip signing): " SIGNING_IDENTITY
    fi
}

# Get team ID from signing identity
get_team_id() {
    if [ -n "$SIGNING_IDENTITY" ]; then
        TEAM_ID=$(security find-identity -v -p codesigning | grep "$SIGNING_IDENTITY" | grep -o 'Team ID: [A-Z0-9]*' | cut -d' ' -f3)
        if [ -n "$TEAM_ID" ]; then
            print_success "Team ID: $TEAM_ID"
        fi
    fi
}

# Clean previous builds
clean_build() {
    print_status "Cleaning previous builds..."
    
    if [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
    
    if [ -d "$PACKAGE_DIR" ]; then
        rm -rf "$PACKAGE_DIR"
    fi
    
    print_success "Build directories cleaned"
}

# Build the app
build_app() {
    print_status "Building $APP_NAME..."
    
    # Create build directory
    mkdir -p "$BUILD_DIR"
    
    # Build the app
    xcodebuild -project MonitorClient.xcodeproj \
               -scheme MonitorClient \
               -configuration Release \
               -derivedDataPath "$BUILD_DIR" \
               build
    
    if [ $? -ne 0 ]; then
        print_error "Build failed"
        exit 1
    fi
    
    print_success "App built successfully"
}

# Sign the app
sign_app() {
    if [ -z "$SIGNING_IDENTITY" ]; then
        print_warning "Skipping code signing - no signing identity provided"
        return
    fi
    
    print_status "Signing app with identity: $SIGNING_IDENTITY"
    
    local app_path="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
    
    if [ ! -d "$app_path" ]; then
        print_error "App not found at: $app_path"
        exit 1
    fi
    
    # Sign the app
    codesign --force --deep --sign "$SIGNING_IDENTITY" \
             --options runtime \
             --entitlements MonitorClient/MonitorClient.entitlements \
             "$app_path"
    
    if [ $? -ne 0 ]; then
        print_error "Code signing failed"
        exit 1
    fi
    
    # Verify the signature
    print_status "Verifying signature..."
    codesign --verify --verbose=4 "$app_path"
    
    if [ $? -eq 0 ]; then
        print_success "App signed and verified successfully"
    else
        print_error "Signature verification failed"
        exit 1
    fi
}

# Create package structure
create_package_structure() {
    print_status "Creating package structure..."
    
    # Create package directory
    mkdir -p "$PACKAGE_DIR"
    mkdir -p "$PACKAGE_DIR/Applications"
    
    # Copy the built app
    cp -R "$BUILD_DIR/Build/Products/Release/$APP_NAME.app" "$PACKAGE_DIR/Applications/"
    
    print_success "Package structure created"
}

# Create component plist
create_component_plist() {
    print_status "Creating component plist..."
    
    cat > component.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <true/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
        <key>RootRelativeBundlePath</key>
        <string>Applications/${APP_NAME}.app</string>
    </dict>
</array>
</plist>
EOF
    
    print_success "Component plist created"
}

# Create postinstall script
create_postinstall_script() {
    print_status "Creating postinstall script..."
    
    cat > postinstall << 'EOF'
#!/bin/bash

# Postinstall script for MonitorClient
BUNDLE_ID="com.airentech.MonitorClient"
APP_NAME="MonitorClient"

# Set permissions
chmod -R 755 "/Applications/$APP_NAME.app"
chown -R root:wheel "/Applications/$APP_NAME.app"

# Create LaunchAgent plist content
LAUNCH_AGENT_CONTENT='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.airentech.MonitorClient</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/MonitorClient.app/Contents/MacOS/MonitorClient</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/MonitorClient.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/MonitorClient.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>'

# Create system-wide LaunchAgent
SYSTEM_LAUNCH_AGENT="/Library/LaunchAgents/${BUNDLE_ID}.plist"
echo "$LAUNCH_AGENT_CONTENT" > "$SYSTEM_LAUNCH_AGENT"
chmod 644 "$SYSTEM_LAUNCH_AGENT"
chown root:wheel "$SYSTEM_LAUNCH_AGENT"

# Load system LaunchAgent
launchctl unload "$SYSTEM_LAUNCH_AGENT" 2>/dev/null || true
launchctl load "$SYSTEM_LAUNCH_AGENT"

# Create user-specific LaunchAgent
USER_LAUNCH_AGENT="$HOME/Library/LaunchAgents/${BUNDLE_ID}.plist"
mkdir -p "$(dirname "$USER_LAUNCH_AGENT")"
echo "$LAUNCH_AGENT_CONTENT" > "$USER_LAUNCH_AGENT"
chmod 644 "$USER_LAUNCH_AGENT"
chown "$USER" "$USER_LAUNCH_AGENT"
launchctl unload "$USER_LAUNCH_AGENT" 2>/dev/null || true
launchctl load "$USER_LAUNCH_AGENT"

exit 0
EOF
    
    chmod +x postinstall
    print_success "Postinstall script created"
}

# Create component package
create_component_package() {
    print_status "Creating component package..."
    
    pkgbuild --root "$PACKAGE_DIR" \
             --component-plist component.plist \
             --identifier "$BUNDLE_ID" \
             --version "$VERSION" \
             --install-location "/" \
             --scripts . \
             "$BUILD_DIR/${APP_NAME}-${VERSION}.pkg"
    
    if [ $? -ne 0 ]; then
        print_error "Component package creation failed"
        exit 1
    fi
    
    print_success "Component package created"
}

# Sign the package
sign_package() {
    if [ -z "$SIGNING_IDENTITY" ]; then
        print_warning "Skipping package signing - no signing identity provided"
        return
    fi
    
    print_status "Signing package with identity: $SIGNING_IDENTITY"
    
    local package_path="$BUILD_DIR/${APP_NAME}-${VERSION}.pkg"
    
    # Try to sign the package
    productsign --sign "$SIGNING_IDENTITY" \
                "$package_path" \
                "$BUILD_DIR/${APP_NAME}-${VERSION}-signed.pkg"
    
    if [ $? -ne 0 ]; then
        print_warning "Package signing failed - this requires an installer signing identity"
        print_warning "The package will be distributed unsigned"
        print_warning "To sign packages, you need a Developer ID Installer certificate"
        return
    fi
    
    # Replace unsigned package with signed one
    mv "$BUILD_DIR/${APP_NAME}-${VERSION}-signed.pkg" "$package_path"
    
    print_success "Package signed successfully"
}

# Create distribution package
create_distribution_package() {
    print_status "Creating distribution package..."
    
    # Create distribution XML
    cat > "$BUILD_DIR/distribution.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>${APP_NAME} Installer</title>
    <organization>${BUNDLE_ID}</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="false"/>
    <pkg-ref id="${BUNDLE_ID}"/>
    <choices-outline>
        <line choice="${BUNDLE_ID}"/>
    </choices-outline>
    <choice id="${BUNDLE_ID}" title="${APP_NAME}">
        <pkg-ref id="${BUNDLE_ID}"/>
    </choice>
    <pkg-ref id="${BUNDLE_ID}" version="${VERSION}" onConclusion="none">${APP_NAME}-${VERSION}.pkg</pkg-ref>
</installer-gui-script>
EOF
    
    # Create distribution package
    productbuild --distribution "$BUILD_DIR/distribution.xml" \
                 --package-path "$BUILD_DIR" \
                 --resources . \
                 "${APP_NAME}-${VERSION}-Installer.pkg"
    
    if [ $? -ne 0 ]; then
        print_error "Distribution package creation failed"
        exit 1
    fi
    
    print_success "Distribution package created: ${APP_NAME}-${VERSION}-Installer.pkg"
}

# Sign the distribution package
sign_distribution_package() {
    if [ -z "$SIGNING_IDENTITY" ]; then
        print_warning "Skipping distribution package signing - no signing identity provided"
        return
    fi
    
    print_status "Signing distribution package..."
    
    local dist_package="${APP_NAME}-${VERSION}-Installer.pkg"
    
    # Try to sign the distribution package
    productsign --sign "$SIGNING_IDENTITY" \
                "$dist_package" \
                "${APP_NAME}-${VERSION}-Installer-signed.pkg"
    
    if [ $? -ne 0 ]; then
        print_warning "Distribution package signing failed - this requires an installer signing identity"
        print_warning "The package will be distributed unsigned"
        print_warning "To sign packages, you need a Developer ID Installer certificate"
        return
    fi
    
    # Replace unsigned package with signed one
    mv "${APP_NAME}-${VERSION}-Installer-signed.pkg" "$dist_package"
    
    print_success "Distribution package signed successfully"
}

# Create notarization script
create_notarization_script() {
    if [ -z "$SIGNING_IDENTITY" ]; then
        print_warning "Skipping notarization script creation - no signing identity"
        return
    fi
    
    print_status "Creating notarization script..."
    
    cat > notarize.sh << 'EOF'
#!/bin/bash

# Notarization script for MonitorClient
# Requires Apple Developer Program membership

set -e

APP_NAME="MonitorClient"
VERSION="1.0"
BUNDLE_ID="com.airentech.MonitorClient"

echo "=== MonitorClient Notarization ==="

# Check if we have the signed package
if [ ! -f "${APP_NAME}-${VERSION}-Installer.pkg" ]; then
    echo "ERROR: Signed package not found. Run build_sign.sh first."
    exit 1
fi

# Get Apple ID credentials
read -p "Enter your Apple ID: " APPLE_ID
read -s -p "Enter your App-Specific Password: " APP_SPECIFIC_PASSWORD
echo

# Submit for notarization
echo "Submitting package for notarization..."
xcrun notarytool submit "${APP_NAME}-${VERSION}-Installer.pkg" \
    --apple-id "$APPLE_ID" \
    --password "$APP_SPECIFIC_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

if [ $? -eq 0 ]; then
    echo "Notarization successful!"
    echo "Package is ready for distribution."
else
    echo "Notarization failed. Check the logs above."
    exit 1
fi
EOF
    
    chmod +x notarize.sh
    print_success "Notarization script created: notarize.sh"
}

# Cleanup temporary files
cleanup() {
    print_status "Cleaning up temporary files..."
    
    rm -f component.plist postinstall
    rm -rf "$BUILD_DIR" "$PACKAGE_DIR"
    
    print_success "Cleanup completed"
}

# Main execution
main() {
    print_status "Starting MonitorClient build and sign process..."
    
    # Check if we're in the right directory
    if [ ! -f "MonitorClient.xcodeproj/project.pbxproj" ]; then
        print_error "MonitorClient.xcodeproj not found. Please run this script from the project root directory."
        exit 1
    fi
    
    check_prerequisites
    auto_detect_signing_identity
    get_team_id
    clean_build
    build_app
    sign_app
    create_package_structure
    create_component_plist
    create_postinstall_script
    create_component_package
    sign_package
    create_distribution_package
    sign_distribution_package
    create_notarization_script
    cleanup
    
    print_success "Build and sign process completed successfully!"
    print_status "Generated files:"
    echo "  - ${APP_NAME}-${VERSION}-Installer.pkg (Signed installation package)"
    if [ -n "$SIGNING_IDENTITY" ]; then
        echo "  - notarize.sh (Notarization script - optional)"
    fi
    echo ""
    print_status "To install:"
    echo "  sudo installer -pkg ${APP_NAME}-${VERSION}-Installer.pkg -target /"
    echo ""
    if [ -n "$SIGNING_IDENTITY" ]; then
        print_status "To notarize (optional, requires Apple Developer Program):"
        echo "  ./notarize.sh"
        echo ""
    fi
    print_warning "Note: The app will automatically start on system boot and run in the background."
    print_warning "Look for the 🗒️ icon in the menu bar to access the app."
}

# Run main function
main "$@" 