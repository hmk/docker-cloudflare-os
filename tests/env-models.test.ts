// Run inside upstream's workshop-backend/__tests__ with its workerd Vitest config.
import { describe, expect, it } from "vitest";
import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { SUGGESTED_MODELS } from "@gadgets/workshop-shared/api";
import { getEnvModelsConfig } from "../src/env-models.js";
import { serializeAdminConfig } from "../src/admin-config.js";
import { DEFAULT_ADMIN_CONFIG } from "../src/storage-schema/admin-settings-storage.js";
import type { UserDurableObject } from "../src/user.js";

declare module "cloudflare:workers" {
  interface ProvidedEnv {
    TEST_USER: DurableObjectNamespace<UserDurableObject>;
  }
}

const id = Object.keys(SUGGESTED_MODELS.anthropic)[0];
let counter = 0;
function withEnv(f: (user: UserDurableObject) => Promise<void>, gateway = false) {
  return runInDurableObject(env.TEST_USER.getByName(`env-models-${++counter}`), async user => {
    const impl = user as unknown as { env: Cloudflare.Env };
    const original = impl.env;
    impl.env = {
      ...original,
      ANTHROPIC_API_KEY: "deployment-test-key",
      ...(gateway && {
        CF_AI_GATEWAY: "test-gateway",
        CF_AI_GATEWAY_ACCOUNT_ID: "test-account",
        CF_AI_GATEWAY_API_TOKEN: "gateway-test-key",
        CF_AI_GATEWAY_PROVIDERS: "anthropic",
        BLUEPRINTS: { get: async () => serializeAdminConfig({
          ...DEFAULT_ADMIN_CONFIG, modelModes: { [id]: "disabled" },
        }) } as unknown as KVNamespace,
      }),
    };
    try { await f(user); } finally { impl.env = original; }
  });
}

describe("deployment-wide env models", () => {
  it("lists, selects and resolves models without exposing the API key in listings", () =>
    withEnv(async user => {
      const listed = await user.listModels();
      expect(listed.some(model => model.id === id)).toBe(true);
      expect(JSON.stringify(listed)).not.toContain("deployment-test-key");
      await user.setPreferredModel(id);
      expect((await user.getChatContext(id)).aiModel?.config.apiToken)
          .toBe("deployment-test-key");
      expect((await user.getExternalMessageChatContext(null)).aiModel?.profile.id).toBe(id);
    }));

  it("deduplicates a user model and resolves the deployment key first", () =>
    withEnv(async user => {
      await user.addModel({ type: "agent", id, name: "User copy" }, {
        provider: "anthropic", model: id, apiToken: "user-test-key",
      });
      expect((await user.listModels()).filter(model => model.id === id)).toHaveLength(1);
      expect((await user.getChatContext(id)).aiModel?.config.apiToken)
          .toBe("deployment-test-key");
    }));

  it("does not restore a gateway model disabled by the admin", () =>
    withEnv(async user => {
      expect((await user.listModels()).some(model => model.id === id)).toBe(false);
      await expect(user.setPreferredModel(id)).rejects.toThrow("No such model");
      await expect(user.getChatContext(id)).rejects.toThrow("disabled");
    }, true));

  it("ignores missing keys and inherited model IDs", () => {
    expect(getEnvModelsConfig({} as Cloudflare.Env)).toBeNull();
    const config = getEnvModelsConfig({ ANTHROPIC_API_KEY: "test" } as Cloudflare.Env)!;
    expect(config.resolveModel("constructor")).toBeUndefined();
    expect(config.resolveModel("unknown-model")).toBeUndefined();
  });
});
