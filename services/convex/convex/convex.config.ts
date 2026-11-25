// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { defineApp } from "convex/server"
import agent from "@convex-dev/agent/convex.config.js"
import rag from "@convex-dev/rag/convex.config.js"
import rateLimiter from "@convex-dev/rate-limiter/convex.config.js"

const app = defineApp()

app.use(agent)
app.use(rag)
app.use(rateLimiter)

export default app
