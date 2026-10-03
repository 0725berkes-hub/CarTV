# Native YouTube CarPlay experiment

This modifies the supplied YouTube executable, injecting a compiled Objective-C
CarPlay scene delegate through an added Mach-O LC_LOAD_DYLIB command. It is not
a CarTV feature or a screen broadcast. It attempts to transfer YouTube's actual
root view controller to a CPWindow and restore it to the phone on disconnect.

The copy uses the existing `com.sedki.carplay-video-test` development profile,
including its authorized CarPlay video entitlement. It does not replace CarTV
or alter the input IPA. Installing it may replace an existing app with that
same test bundle identifier. Only devices registered in the profile can install it.

## Validation and limits

Compilation, local code-signature verification, and packaging are checked by
the build script. Actual CarPlay display, playback, sign-in, and touch input
have not been tested. This is an unsupported UI experiment, not Apple's
CarPlay video template/AirPlay integration. The entitlement does not guarantee
that iOS provides a drawable CPWindow. A template-only connection displays an
explicit failure message instead of claiming the native interface works.

Changing Google's app identity and signing team may break keychain access,
sign-in, app groups, DRM, or other app assumptions. Google's original entitlements
are not copied to the new signature. App extensions are removed because their
identities are not covered by this app profile. The phone displays a placeholder
while its controller is attached to the car. The experiment adds no workaround
for vehicle video restrictions; test while parked in a compatible vehicle.

## Build

Run `python3 build_experiment.py --help` for input, profile, identity and output
arguments. The script requires Xcode command-line tools and a usable local signing
identity. Use a separate CarPlay video development profile, not CarTV's identity.

## Device test

Install the generated IPA using Xcode or Apple Configurator on a registered
physical iPhone. Open the test YouTube app on the phone first, then connect to
CarPlay while parked and select `YouTube CarPlay Test` if it appears. Inspect
device logs for `[YouTubeCarPlay]` if no interface appears. Disconnect to restore
the native controller to the phone. Report whether the icon appears, whether a
native interface or the template-only message appears, and whether video plays.
