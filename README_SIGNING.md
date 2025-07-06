# MonitorClient Build and Sign Guide

This guide explains how to build, sign, and optionally notarize your MonitorClient app for distribution on macOS.

## What is Code Signing?

Code signing is a security feature in macOS that:
- Verifies the app comes from a trusted developer
- Prevents "Unknown Developer" warnings
- Allows the app to run without Gatekeeper restrictions
- Enables distribution outside the Mac App Store

## Prerequisites

### 1. Apple Developer Program Membership
- Required for distribution outside Mac App Store
- Provides Developer ID certificates
- Enables notarization

### 2. Xcode and Command Line Tools
```bash
# Install Xcode command line tools
xcode-select --install
```

### 3. Developer Certificates
You need one of these certificates:
- **Developer ID Application** (recommended for distribution)
- **Apple Development** (for testing)

## Getting Developer Certificates

### Option 1: Automatic (Recommended)
1. Open Xcode
2. Go to Xcode → Preferences → Accounts
3. Add your Apple ID
4. Click "Manage Certificates"
5. Click "+" to create new certificates

### Option 2: Manual
1. Go to [Apple Developer Portal](https://developer.apple.com/account/)
2. Navigate to Certificates, Identifiers & Profiles
3. Create a Developer ID Application certificate
4. Download and install in Keychain Access

## Using the Build Script

### 1. Build and Sign
```bash
# Make the script executable
chmod +x build_sign.sh

# Run the build and sign process
./build_sign.sh
```

The script will:
- Auto-detect your signing identity
- Build the app
- Sign the app and package
- Create a signed installer

### 2. Install the Signed Package
```bash
sudo installer -pkg MonitorClient-1.0-Installer.pkg -target /
```

## Notarization (Optional)

Notarization is Apple's process for scanning apps for malicious code. It's required for:
- Distribution outside Mac App Store
- Avoiding Gatekeeper warnings on macOS Catalina+

### Prerequisites for Notarization
- Apple Developer Program membership
- App-Specific Password (not your regular Apple ID password)

### Create App-Specific Password
1. Go to [Apple ID website](https://appleid.apple.com/)
2. Sign in with your Apple ID
3. Go to Security → App-Specific Passwords
4. Generate a new password for "Xcode"

### Run Notarization
```bash
# Run the notarization script
./notarize.sh
```

Follow the prompts to enter your Apple ID and App-Specific Password.

## Manual Signing Commands

If you prefer to sign manually:

### Sign the App
```bash
codesign --force --deep --sign "Developer ID Application: Your Name (TEAM_ID)" \
         --options runtime \
         --entitlements MonitorClient/MonitorClient.entitlements \
         MonitorClient.app
```

### Sign the Package
```bash
productsign --sign "Developer ID Application: Your Name (TEAM_ID)" \
            unsigned.pkg signed.pkg
```

### Notarize Manually
```bash
xcrun notarytool submit MonitorClient-1.0-Installer.pkg \
    --apple-id "your-apple-id@example.com" \
    --password "app-specific-password" \
    --team-id "TEAM_ID" \
    --wait
```

## Troubleshooting

### Common Issues

#### 1. "No signing identity found"
**Solution**: Create a Developer ID certificate in Xcode or Apple Developer Portal

#### 2. "Code signing failed"
**Solution**: 
- Check certificate is valid: `security find-identity -v -p codesigning`
- Ensure certificate is in Keychain Access
- Verify entitlements file exists

#### 3. "Notarization failed"
**Solution**:
- Check Apple ID and App-Specific Password
- Ensure you have Apple Developer Program membership
- Verify the app is properly signed before notarization

#### 4. "Gatekeeper still blocks the app"
**Solution**:
- Ensure the app is notarized
- Check that the notarization was successful
- Users may need to right-click and select "Open" the first time

### Verification Commands

#### Check App Signature
```bash
codesign --verify --verbose=4 MonitorClient.app
```

#### Check Package Signature
```bash
pkgutil --check-signature MonitorClient-1.0-Installer.pkg
```

#### List Signing Identities
```bash
security find-identity -v -p codesigning
```

## Distribution

### For Internal Use
- Signed package is sufficient
- Users can install with `sudo installer -pkg file.pkg -target /`

### For External Distribution
- Notarization is required
- Upload to your website or distribution platform
- Users can install normally without warnings

### Mac App Store
- Requires different certificates and process
- Not covered in this guide

## Security Best Practices

1. **Keep certificates secure**: Store in Keychain Access
2. **Use App-Specific Passwords**: Never use your main Apple ID password
3. **Regular updates**: Renew certificates before expiration
4. **Test thoroughly**: Test signed apps on clean systems

## File Structure After Build

```
Project Directory/
├── MonitorClient-1.0-Installer.pkg    # Signed installer
├── notarize.sh                        # Notarization script
├── build_sign.sh                      # Build and sign script
└── README_SIGNING.md                  # This guide
```

## Next Steps

1. **Test the signed app** on a clean macOS system
2. **Notarize the package** if distributing externally
3. **Distribute the package** to your users
4. **Monitor for issues** and update as needed

## Support

If you encounter issues:
1. Check the troubleshooting section above
2. Verify all prerequisites are met
3. Check Apple Developer documentation
4. Review Xcode and macOS logs for detailed error messages 