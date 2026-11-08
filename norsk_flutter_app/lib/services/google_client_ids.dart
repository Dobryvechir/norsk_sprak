// OAuth client IDs from Google Cloud (see "Google Drive sign-in" in README.md). They identify the
// app and are not secrets. While one is empty, Google Drive can't be connected on that platform.

/// The "Web application" client: used by the web app, and by Android as its server client ID.
const googleWebClientId = '';

/// The "iOS" client. Its reversed form also goes in `ios/Flutter/GoogleSignIn.xcconfig`.
const googleIosClientId = '';
