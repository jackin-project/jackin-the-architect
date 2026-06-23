#!/usr/bin/env rust-script

use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

const DEFAULT_SOURCE_URL: &str =
    "https://raw.githubusercontent.com/jackin-project/jackin/refs/heads/main/mise.toml";
const DEFAULT_RUST_TOOLCHAIN_URL: &str =
    "https://raw.githubusercontent.com/jackin-project/jackin/refs/heads/main/rust-toolchain.toml";
const DEFAULT_OUTPUT: &str = "jackin-toolchain/mise.toml";
const DEFAULT_RUST_TOOLCHAIN_OUTPUT: &str = "jackin-toolchain/rust-toolchain.toml";

fn main() {
    if let Err(error) = run() {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let source_url = env::var("JACKIN_MISE_URL").unwrap_or_else(|_| DEFAULT_SOURCE_URL.to_string());
    let rust_toolchain_url = env::var("JACKIN_RUST_TOOLCHAIN_URL")
        .unwrap_or_else(|_| DEFAULT_RUST_TOOLCHAIN_URL.to_string());
    let mut args = env::args().skip(1);
    let output = args.next().unwrap_or_else(|| DEFAULT_OUTPUT.to_string());
    let rust_toolchain_output = args
        .next()
        .unwrap_or_else(|| DEFAULT_RUST_TOOLCHAIN_OUTPUT.to_string());

    let source = download(&source_url)?;
    let tools = extract_tools(&source)?;
    write_output(&output, &tools)?;

    let rust_toolchain = download(&rust_toolchain_url)?;
    write_output(&rust_toolchain_output, &rust_toolchain)?;

    Ok(())
}

fn download(source_url: &str) -> Result<String, String> {
    let output = Command::new("curl")
        .args(["-fsSL", source_url])
        .output()
        .map_err(|error| format!("failed to execute curl: {error}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "failed to download {source_url}: curl exited with status {}: {}",
            output.status,
            stderr.trim()
        ));
    }

    String::from_utf8(output.stdout)
        .map_err(|error| format!("downloaded {source_url} was not valid UTF-8: {error}"))
}

fn extract_tools(source: &str) -> Result<String, String> {
    let mut in_tools = false;
    let mut tool_lines = Vec::new();

    for line in source.lines() {
        let trimmed = line.trim();

        if trimmed == "[tools]" {
            in_tools = true;
            continue;
        }

        if in_tools && trimmed.starts_with('[') {
            break;
        }

        if in_tools && !trimmed.is_empty() && !trimmed.starts_with('#') {
            tool_lines.push(line.to_string());
        }
    }

    if tool_lines.is_empty() {
        return Err("upstream mise.toml did not contain any [tools] entries".to_string());
    }

    let mut output = String::from("[tools]\n");
    output.push_str(&tool_lines.join("\n"));
    normalize_cross_arch_cargo_tools(&mut output);
    output.push('\n');
    Ok(output)
}

fn normalize_cross_arch_cargo_tools(output: &mut String) {
    *output = output
        .lines()
        .map(|line| {
            let Some(version) = line
                .trim()
                .strip_prefix("\"cargo:cargo-fuzz\" = ")
                .and_then(|value| value.strip_prefix('"'))
                .and_then(|value| value.strip_suffix('"'))
            else {
                return line.to_string();
            };

            format!(
                "\"cargo:cargo-fuzz\" = {{ version = \"{version}\", default-features = false }}"
            )
        })
        .collect::<Vec<_>>()
        .join("\n");
}

fn write_output(output: &str, contents: &str) -> Result<(), String> {
    let output_path = Path::new(output);
    if let Some(parent) = output_path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed to create {}: {error}", parent.display()))?;
    }

    fs::write(output_path, contents)
        .map_err(|error| format!("failed to write {}: {error}", output_path.display()))
}
