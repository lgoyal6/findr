/* The native bridge accepts only upload sessions created by this extension. */
const extensionAPI = globalThis.browser || globalThis.chrome;
const nativeApplication = "io.github.lgoyal6.findr.browser";

extensionAPI.runtime.onConnect.addListener((port) => {
    if (port.name !== "leaf-upload" || !port.sender?.tab || !port.sender.url) return;
    let session;
    let disconnected = false;
    let started = false;

    const native = async (message) => {
        const response = await extensionAPI.runtime.sendNativeMessage(nativeApplication, message);
        if (response?.status === "error") throw new Error(response.error || "Leaf could not complete the upload.");
        return response;
    };

    port.onDisconnect.addListener(() => {
        disconnected = true;
        if (session) native({ action: "cancel", session }).catch(() => {});
    });

    port.onMessage.addListener(async (request) => {
        if (request.action !== "choose" || started) return;
        started = true;
        try {
            const page = new URL(port.sender.url.startsWith("about:") ? port.sender.origin : port.sender.url);
            if (!["https:", "http:", "file:"].includes(page.protocol)) throw new Error("This page cannot use Leaf uploads.");
            const origin = page.protocol === "file:" ? "file:///" : page.origin;
            const pending = await native({ action: "choose", origin,
                accept: String(request.accept || "").slice(0, 4096), multiple: Boolean(request.multiple) });
            session = pending.session;
            if (!session) throw new Error("Leaf did not create an upload session.");
            const deadline = Date.now() + 600000;
            let response;
            do {
                if (disconnected) return;
                await new Promise((resolve) => setTimeout(resolve, 150));
                response = await native({ action: "status", session });
            } while (response.status === "pending" && Date.now() < deadline);
            if (response.status === "cancelled") { port.postMessage({ action: "cancel" }); return; }
            if (response.status !== "selected" || !Array.isArray(response.files)) throw new Error("The upload request expired. Try again.");
            port.postMessage({ action: "files", files: response.files });
            for (let index = 0; index < response.files.length; index++) {
                let offset = 0;
                while (offset < response.files[index].size) {
                    if (disconnected) return;
                    const chunk = await native({ action: "read", session, index, offset });
                    if (!chunk.length || chunk.length > response.files[index].size - offset) throw new Error("Leaf could not read the chosen file.");
                    port.postMessage({ action: "chunk", index, data: chunk.data });
                    offset += chunk.length;
                }
            }
            port.postMessage({ action: "complete" });
        } catch (error) {
            if (!disconnected) port.postMessage({ action: "error", error: error.message || "Open Leaf and try again." });
        } finally {
            if (session) {
                await native({ action: "finish", session }).catch(() => {});
                session = undefined;
            }
        }
    });
});
