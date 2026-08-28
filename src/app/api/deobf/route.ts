import { NextRequest, NextResponse } from "next/server";
import { execFile } from "child_process";
import { promisify } from "util";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";

const execFileAsync = promisify(execFile);

export const runtime = "nodejs";
export const maxDuration = 60;

type Tool = "moonsec" | "prometheus";

interface DeobfRequest {
  tool: Tool;
  code: string;
}

function runtimeDir(): string {
  // on macOS process.platform is "darwin", but our folder is "osx"; on Vercel it's linux
  const folder = process.platform === "darwin" ? "osx" : "linux";
  return path.join(process.cwd(), "runtimes", folder);
}

function runtimesExist(): { osx: boolean; linux: boolean; current: string } {
  const osx = fs.existsSync(path.join(process.cwd(), "runtimes", "osx"));
  const linux = fs.existsSync(path.join(process.cwd(), "runtimes", "linux"));
  return { osx, linux, current: process.platform };
}

async function runCommand(cmd: string, args: string[], opts: any): Promise<{ stdout: string; stderr: string }> {
  try {
    const r = await execFileAsync(cmd, args, { ...opts, maxBuffer: 64 * 1024 * 1024, timeout: 55000 });
    const stdout = Buffer.isBuffer(r.stdout) ? r.stdout.toString("utf-8") : String(r.stdout);
    const stderr = Buffer.isBuffer(r.stderr) ? r.stderr.toString("utf-8") : String(r.stderr);
    return { stdout, stderr };
  } catch (e: any) {
    const err = e as any;
    const s1 = Buffer.isBuffer(err.stdout) ? err.stdout.toString("utf-8") : String(err.stdout || "");
    const s2 = Buffer.isBuffer(err.stderr) ? err.stderr.toString("utf-8") : String(err.stderr || "");
    return { stdout: s1, stderr: s2 || (err.message || String(e)) };
  }
}

export async function POST(req: NextRequest) {
  try {
    const body = (await req.json()) as DeobfRequest;
    const tool = body?.tool;
    const code = body?.code ?? "";

    if (!tool || !code) {
      return NextResponse.json({ error: "Missing tool or code" }, { status: 400 });
    }
    if (!["moonsec", "prometheus"].includes(tool)) {
      return NextResponse.json({ error: "Invalid tool" }, { status: 400 });
    }

    const rt = runtimesExist();

    const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "deobf-"));
    const inFile = path.join(workDir, "input.lua");
    fs.writeFileSync(inFile, code, "utf-8");

    const rtBase = runtimeDir();

    let result: { outFile: string; isBinary: boolean; stdout: string; stderr: string } | null = null;

    if (tool === "moonsec") {
      const bin = path.join(rtBase, "moonsec", "MoonsecDeobfuscator");
      const outFile = path.join(workDir, "output.lua");
      // structured decompiler reconstructs readable Lua source
      const r = await runCommand(bin, ["-decompile", "-i", inFile, "-o", outFile], {
        env: { ...process.env, DOTNET_BUNDLE_EXTRACT_BASE_DIR: os.tmpdir(), HOME: os.tmpdir() },
      });
      result = { outFile, isBinary: false, stdout: r.stdout, stderr: r.stderr };
    } else if (tool === "prometheus") {
      const promDir = path.join(process.cwd(), "runtimes", "promdeobf");
      const mainJs = path.join(promDir, "main.js");
      const outFile = path.join(workDir, "output.lua");
      // main.js may write temp files relative to cwd -> run inside the promdeobf dir
      const r = await runCommand(process.execPath, [mainJs, inFile, outFile], {
        cwd: promDir,
        env: { ...process.env, NODE_PATH: path.join(promDir, "node_modules") },
      });
      result = { outFile, isBinary: false, stdout: r.stdout, stderr: r.stderr };
    }

    if (!result) {
      return NextResponse.json({ error: "Unknown tool" }, { status: 400 });
    }

    const outExists = fs.existsSync(result.outFile);

    let outputText = "";
    let outputBase64: string | null = null;
    if (outExists) {
      const data = fs.readFileSync(result.outFile);
      if (result.isBinary) {
        outputBase64 = data.toString("base64");
      } else {
        outputText = data.toString("utf-8");
      }
    }

    const cleanup = () => {
      try {
        fs.rmSync(workDir, { recursive: true, force: true });
      } catch {}
    };
    cleanup();

    return NextResponse.json({
      tool,
      ok: outExists,
      isBinary: result.isBinary,
      outputText,
      outputBase64,
      log: result.stdout,
      err: result.stderr,
      platformsProbed: rt,
    });
  } catch (e: any) {
    return NextResponse.json({ error: String(e && e.message ? e.message : e) }, { status: 500 });
  }
}
