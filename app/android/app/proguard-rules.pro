# Last modified: 2026-08-01--2003
#
# R8 rules for the release build. Debug builds skip R8 entirely, which is
# why the first-ever release build (2026-08-01, switching the dist page off
# 200MB debug APKs) was what surfaced these — exactly as Task 10's review
# predicted for SMBJ under minification.
#
# Both groups below are compile-time references to classes that do not
# exist on Android and are never reached at runtime:
#   - javax.el.*: mbassy's (SMBJ's event bus) OPTIONAL EL-expression
#     filter support; fooplayer never uses EL filters.
#   - org.ietf.jgss.*: SMBJ's Kerberos/SPNEGO authenticator; fooplayer
#     authenticates as guest (AuthenticationContext.guest()), never GSSAPI.
# -dontwarn (not -keep) is deliberate: the classes are genuinely absent and
# the code paths referencing them are dead on Android.
-dontwarn javax.el.**
-dontwarn org.ietf.jgss.**
