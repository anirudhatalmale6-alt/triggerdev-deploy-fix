import { task } from "@trigger.dev/sdk/v3";
import { uploadToTigris } from "@/utils/storageClient";

export const revenueGateRouter = task({
  id: "revenue-gate-router",
  run: async (payload: { key: string }) => {
    return await uploadToTigris(payload.key, new Uint8Array([1, 2, 3]));
  },
});
