"use client";

import { useState } from "react";

type Tool = "ironbrew" | "moonsec" | "prometheus";

interface DeobfResponse {
  tool: string;
  ok: boolean;
  isBinary: boolean;
  outputText?: string;
  outputBase64?: string | null;
  log?: string;
  err?: string;
}

const TOOLS: { id: Tool; label: string; desc: string; input: string }[] = [
  {
    id: "ironbrew",
    label: "Ironbrew2",
    desc: "Email bytecode (luac)",
    input: "Lua source obfuscated by Ironbrew2",
  },
  {
    id: "moonsec",
    label: "MoonSec V3",
    desc: "Disassembly text",
    input: "Lua source obfuscated by MoonSec V3",
  },
  {
    id: "prometheus",
    label: "Prometheus",
    desc: "Lua source (static)",
    input: "Lua source obfuscated by Prometheus",
  },
];

export default function Home() {
  const [tool, setTool] = useState<Tool>("prometheus");
  const [code, setCode] = useState("");
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<DeobfResponse | null>(null);
  const [error, setError] = useState("");

  async function runDeobf() {
    if (!code.trim()) {
      setError("Hãy dán nội dung obfuscated vào ô trên.");
      return;
    }
    setLoading(true);
    setError("");
    setResult(null);
    try {
      const res = await fetch("/api/deobf", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ tool, code }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Lỗi không xác định");
      } else {
        setResult(data as DeobfResponse);
      }
    } catch (e: any) {
      setError(String(e && e.message ? e.message : e));
    } finally {
      setLoading(false);
    }
  }

  function downloadBinary() {
    if (!result?.outputBase64) return;
    const bin = atob(result.outputBase64);
    const arr = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    const blob = new Blob([arr], { type: "application/octet-stream" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `${tool}-output.luac`;
    a.click();
    URL.revokeObjectURL(url);
  }

  return (
    <main className="min-h-screen bg-zinc-50 text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
      <div className="mx-auto max-w-5xl px-4 py-8">
        <header className="mb-6">
          <h1 className="text-3xl font-bold text-zinc-900 dark:text-white">
            ZZZ-Deobf
          </h1>
          <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">
            Dán nội dung obfuscated, chọn loại obfuscator, bấm Deobfuscate.
          </p>
        </header>

        <section className="mb-4">
          <h2 className="mb-2 text-sm font-semibold text-zinc-600 dark:text-zinc-400">
            Chọn loại obfuscator
          </h2>
          <div className="grid gap-3 sm:grid-cols-3">
            {TOOLS.map((t) => (
              <button
                key={t.id}
                onClick={() => setTool(t.id)}
                className={`rounded-xl border p-4 text-left transition ${
                  tool === t.id
                    ? "border-indigo-500 bg-indigo-500/10 ring-2 ring-indigo-500"
                    : "border-zinc-200 bg-white hover:border-zinc-300 dark:border-zinc-800 dark:bg-zinc-900"
                }`}
              >
                <div className="font-semibold">{t.label}</div>
                <div className="mt-1 text-xs text-zinc-500">{t.desc}</div>
                <div className="mt-1 text-[11px] text-zinc-400">{t.input}</div>
              </button>
            ))}
          </div>
        </section>

        <section>
          <textarea
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="// Dán Lua source đã bị obfuscated vào đây..."
            spellCheck={false}
            className="h-64 w-full resize-y rounded-xl border border-zinc-300 bg-white p-3 font-mono text-sm dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
          />
          <div className="mt-3 flex items-center gap-3">
            <button
              onClick={runDeobf}
              disabled={loading}
              className="rounded-lg bg-indigo-600 px-6 py-2.5 font-semibold text-white transition hover:bg-indigo-500 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {loading ? "Đang xử lý..." : "Deobfuscate"}
            </button>
            <span className="text-xs text-zinc-400">
              {tool === "prometheus"
                ? "Output: Lua source"
                : tool === "moonsec"
                ? "Output: disassembly"
                : "Output: bytecode (.luac)"}
            </span>
          </div>
        </section>

        {error && (
          <div className="mt-4 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-700 dark:border-red-800 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        {result && (
          <section className="mt-6">
            <div className="mb-2 flex items-center gap-3">
              <h2 className="text-sm font-semibold text-zinc-600 dark:text-zinc-400">
                Kết quả
              </h2>
              <span
                className={`rounded-full px-2 py-0.5 text-xs font-medium ${
                  result.ok
                    ? "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300"
                    : "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300"
                }`}
              >
                {result.ok ? "Thành công" : "Thất bại"}
              </span>
              {result.isBinary && result.outputBase64 && (
                <button
                  onClick={downloadBinary}
                  className="rounded-md border border-zinc-300 px-3 py-1 text-xs font-medium hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  Tải .luac
                </button>
              )}
            </div>

            {result.err?.trim() && (
              <pre className="mb-3 overflow-auto rounded-lg border border-red-200 bg-red-50 p-3 text-xs text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
                {result.err}
              </pre>
            )}

            <pre className="max-h-[600px] overflow-auto rounded-xl border border-zinc-200 bg-white p-4 font-mono text-xs dark:border-zinc-800 dark:bg-zinc-900">
              {result.isBinary
                ? result.ok
                  ? "[Bytecode sinh ra — bấm nút 'Tải .luac' để lưu. Để đọc cần dùng Lua decompiler.]"
                  : "(Không tạo được bytecode)"
                : result.outputText || "(Rỗng)"}
            </pre>

            {result.log?.trim() && (
              <details className="mt-2">
                <summary className="cursor-pointer text-xs text-zinc-500">
                  Nhật ký
                </summary>
                <pre className="mt-2 overflow-auto rounded-lg bg-zinc-100 p-3 text-[11px] text-zinc-600 dark:bg-zinc-900 dark:text-zinc-400">
                  {result.log}
                </pre>
              </details>
            )}
          </section>
        )}
      </div>
    </main>
  );
}
