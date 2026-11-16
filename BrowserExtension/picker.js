(() => {
    const originalClick = HTMLInputElement.prototype.click;
    const originalShowPicker = HTMLInputElement.prototype.showPicker;
    const setFiles = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "files").set;
    let pending;
    let nativeFallback = false;

    function supports(input) {
        return input instanceof HTMLInputElement && input.type === "file" &&
            !input.disabled && !input.webkitdirectory && navigator.userActivation.isActive;
    }

    function useNative(input) {
        nativeFallback = true;
        try { originalClick.call(input); }
        finally { nativeFallback = false; }
    }

    function showError(input, message) {
        const host = document.createElement("div");
        const shadow = host.attachShadow({ mode: "closed" });
        const panel = document.createElement("div");
        panel.style.cssText = "position:fixed;right:24px;bottom:24px;z-index:2147483647;max-width:350px;padding:16px;background:#232625;color:#fff;border:1px solid #59635b;border-radius:12px;font:14px system-ui;box-shadow:0 6px 30px #0005";
        const text = document.createElement("p");
        text.style.cssText = "margin:0 0 12px;line-height:1.4";
        text.textContent = message;
        const fallback = document.createElement("button");
        fallback.textContent = "Use macOS picker";
        fallback.onclick = () => { host.remove(); useNative(input); };
        const dismiss = document.createElement("button");
        dismiss.textContent = "Dismiss";
        dismiss.style.marginLeft = "8px";
        dismiss.onclick = () => host.remove();
        panel.append(text, fallback, dismiss);
        shadow.append(panel);
        document.documentElement.append(host);
    }

    function request(input) {
        if (pending) return;
        const id = crypto.randomUUID();
        pending = { id, input, files: [], chunks: [] };
        window.postMessage({ channel: "leaf-upload-request", id,
            accept: input.accept, multiple: input.multiple }, "*");
    }

    document.addEventListener("click", (event) => {
        const input = event.composedPath().find((node) => node instanceof HTMLInputElement && node.type === "file");
        if (!nativeFallback && supports(input)) {
            event.preventDefault();
            request(input);
        }
    }, true);

    HTMLInputElement.prototype.click = function (...args) {
        if (!nativeFallback && supports(this)) { request(this); return; }
        return originalClick.apply(this, args);
    };
    if (originalShowPicker) {
        HTMLInputElement.prototype.showPicker = function (...args) {
            if (!nativeFallback && supports(this)) { request(this); return; }
            return originalShowPicker.apply(this, args);
        };
    }

    window.addEventListener("message", (event) => {
        if (event.source !== window || event.data?.channel !== "leaf-upload-result" ||
            !pending || event.data.id !== pending.id) return;
        const message = event.data;
        const input = pending.input;
        try {
            switch (message.action) {
            case "files":
                pending.files = message.files;
                pending.chunks = message.files.map(() => []);
                break;
            case "chunk": {
                const binary = atob(message.data);
                const bytes = new Uint8Array(binary.length);
                for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index);
                pending.chunks[message.index].push(bytes);
                break;
            }
            case "complete": {
                const transfer = new DataTransfer();
                pending.files.forEach((file, index) => {
                    const result = new File(pending.chunks[index], file.name,
                        { type: file.type, lastModified: file.lastModified });
                    if (result.size !== file.size) throw new Error("The selected file did not transfer completely. Try again.");
                    transfer.items.add(result);
                });
                setFiles.call(input, transfer.files);
                pending = undefined;
                input.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
                input.dispatchEvent(new Event("change", { bubbles: true }));
                break;
            }
            case "cancel":
                pending = undefined;
                input.dispatchEvent(new Event("cancel", { bubbles: true }));
                break;
            case "error":
                pending = undefined;
                showError(input, message.error);
                break;
            }
        } catch (error) {
            pending = undefined;
            showError(input, error.message);
        }
    });
})();
