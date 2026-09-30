// Loader: typebox → local stub (see typebox-stub.register.mjs).
export async function resolve(specifier, context, next) {
  if (specifier === "typebox") {
    return {
      shortCircuit: true,
      url: new URL("./typebox-stub.mjs", import.meta.url).href,
    };
  }
  return next(specifier, context);
}
