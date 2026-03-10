// Utility functions

// Returns the first non-null value from a map, given a list of keys, as a string.
// Returns null if no value is found.
String? firstValueAsString(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    if (m.containsKey(k) && m[k] != null) {
      final v = m[k];
      return v.toString();
    }
  }
  return null;
}

// Returns the first non-empty, trimmed string value from a map, given a list of keys.
// Returns an empty string if no value is found.
String firstNonEmptyString(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    if (m.containsKey(k) && m[k] != null) {
      final s = m[k].toString().trim();
      if (s.isNotEmpty) return s;
    }
  }
  return '';
}