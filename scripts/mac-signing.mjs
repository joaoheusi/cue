export function selectSigningIdentity(output, requested) {
  const identities = [...output.matchAll(/\b([A-Fa-f0-9]{40}) "([^"]+)"/g)]
    .map(([, hash, name]) => ({ hash: hash.toUpperCase(), name }))
    .filter(({ name }) => name.startsWith("Developer ID Application: "));
  const matches = requested
    ? identities.filter(
        ({ hash, name }) =>
          hash === requested.toUpperCase() || name === requested,
      )
    : identities;
  if (!matches.length) {
    throw new Error(
      "A valid Developer ID Application identity is required. Set APPLE_SIGNING_IDENTITY to its certificate name or SHA-1 fingerprint. Unsigned installers lose Accessibility access after updates.",
    );
  }
  if (new Set(matches.map(({ name }) => name)).size !== 1) {
    throw new Error(
      "Multiple Developer ID identities found. Set APPLE_SIGNING_IDENTITY to the identity used for previous Cue releases.",
    );
  }
  // Renewed certificates for the same Developer ID share the same designated requirement.
  return matches.sort((a, b) => a.hash.localeCompare(b.hash))[0].hash;
}

export function verifySigningIdentity(details, requirement, identifier) {
  if (
    !details.includes(`Identifier=${identifier}\n`) ||
    !/^TeamIdentifier=[A-Z0-9]+$/m.test(details) ||
    !details.includes("Authority=Developer ID Application:") ||
    !requirement.includes("anchor apple generic") ||
    requirement.includes("cdhash")
  ) {
    throw new Error(
      "Cue must have a Developer ID signature tied to its bundle and team, not a build-specific code hash.",
    );
  }
}
