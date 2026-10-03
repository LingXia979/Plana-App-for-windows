/// JSON numbers with no insignificant decimal zeroes. Never round a value or
/// stringify a numeric field: encoding parameters must retain their exact value.
num canonicalNumber(num value) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', 'must be finite');
  }
  return value == value.roundToDouble() ? value.toInt() : value;
}
