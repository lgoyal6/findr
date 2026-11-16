(() => {
    const api = globalThis.browser || globalThis.chrome;
    const active = new Map();
    const send = (id, payload) => window.postMessage({ channel: "leaf-upload-result", id, ...payload }, "*");

    window.addEventListener("message", (event) => {
        if (event.source !== window || event.data?.channel !== "leaf-upload-request") return;
        if (!navigator.userActivation.isActive) return;
        const { id, accept, multiple } = event.data;
        if (typeof id !== "string" || active.size || id.length > 100) return;
        const port = api.runtime.connect({ name: "leaf-upload" });
        active.set(id, port);
        let completed = false;
        port.onMessage.addListener((message) => {
            send(id, message);
            if (["complete", "cancel", "error"].includes(message.action)) {
                completed = true;
                active.delete(id);
                port.disconnect();
            }
        });
        port.onDisconnect.addListener(() => {
            active.delete(id);
            if (!completed) send(id, { action: "error", error: "Leaf’s browser connection closed. Open Leaf and try again." });
        });
        port.postMessage({ action: "choose", accept, multiple });
    });

    window.addEventListener("pagehide", () => {
        for (const port of active.values()) port.disconnect();
        active.clear();
    });
})();
