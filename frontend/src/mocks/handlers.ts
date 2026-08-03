import { authHandlers } from "./handlers/auth";
import { pipelineHandlers } from "./handlers/pipelines";
import { githubHandlers } from "./handlers/github";
import { billingHandlers } from "./handlers/billing";
import { apikeyHandlers } from "./handlers/apikeys";
import { orgHandlers } from "./handlers/org";

export const handlers = [
  ...authHandlers,
  ...pipelineHandlers,
  ...githubHandlers,
  ...billingHandlers,
  ...apikeyHandlers,
  ...orgHandlers,
];
