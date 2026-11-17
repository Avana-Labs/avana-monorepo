// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The part of the `ws` package's server the WebSocket test uses (the package ships no types).

declare module "ws" {
  interface ServerSocket {
    on(event: "message", listener: (data: unknown) => void): void;
    send(data: string): void;
    terminate(): void;
  }
  export class WebSocketServer {
    constructor(options: { port: number; host?: string });
    readonly clients: Set<ServerSocket>;
    on(event: "listening", listener: () => void): void;
    on(event: "connection", listener: (socket: ServerSocket) => void): void;
    address(): unknown;
    close(cb?: () => void): void;
  }
}
