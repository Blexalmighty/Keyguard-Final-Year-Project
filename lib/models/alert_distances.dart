/// The three distances the proximity alerts are built around.
///
/// Kept together, and out of both `SettingsStore` and `BleService`, because the
/// settings screen, the persistence layer and the service all have to agree
/// about them. When the slider bounds lived only in the widget and the default
/// only in the store, the two could drift apart and a stored value could sit
/// outside the range the slider was willing to display — which Flutter's
/// `Slider` treats as an assertion failure, not a clamp.
library;

/// Smallest alert distance the owner can choose, in metres.
///
/// Below a metre or so the RSSI-derived estimate is not trustworthy: at that
/// range small changes in how the keyholder is oriented in a pocket move the
/// reading more than actually walking away does.
const double kMinAlertDistance = 1.0;

/// Largest alert distance the owner can choose, in metres.
const double kMaxAlertDistance = 10.0;

/// Largest maximum allowance the owner can choose, in metres.
///
/// Thirty metres is about the practical ceiling for BLE indoors. Offering more
/// would let the owner set a limit that can never be reported as crossed,
/// because the link drops first and a dropped link has no distance — it is a
/// disconnect, which the app already treats as its own event.
const double kMaxAllowanceCeiling = 30.0;

/// Default maximum allowance, in metres.
///
/// Set to the top of the alert-distance range so the escalation is meaningful
/// on a fresh install: whatever alert distance the owner picks, the allowance
/// starts strictly outside it.
const double kDefaultMaxAllowance = 10.0;
