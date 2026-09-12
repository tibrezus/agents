// Minimal `typebox` stub for the rig-query extension tests.
//
// The extension (skills/wiki/extensions/rig-query.ts) imports { Type } at
// module level — that import resolves inside pi at runtime, but the test
// harness runs the file standalone. Instead of adding a registry dependency
// for test-only purposes, this stub provides just the surface the extension
// uses; the harness registers it as a resolve hook (typebox-stub.register.mjs).

const schema = (type) => (opts = {}) => ({ type, ...opts });

export const Type = {
  Object: (properties, opts = {}) => ({ type: "object", properties, ...opts }),
  String: schema("string"),
  Boolean: schema("boolean"),
  Number: schema("number"),
  Optional: (t) => t,
};

export default Type;
