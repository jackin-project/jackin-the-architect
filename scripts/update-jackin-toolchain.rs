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
    let mut tool_lines = section_entries(source, "tools");

    if tool_lines.is_empty() {
        return Err("upstream mise.toml did not contain any [tools] entries".to_string());
    }

    let mut alias_lines = section_entries(source, "tool_alias");
    normalize_cross_arch_cargo_tools(&mut tool_lines, &mut alias_lines);

    let mut output = String::from("[tools]\n");
    output.push_str(&tool_lines.join("\n"));
    output.push('\n');

    if !alias_lines.is_empty() {
        output.push_str("\n[tool_alias]\n");
        output.push_str(&alias_lines.join("\n"));
        output.push('\n');
    }

    output.push_str("\n[settings]\n");
    output.push_str("cargo.binstall = true\n");

    for line in section_entries(source, "settings") {
        if line.trim_start().starts_with("idiomatic_version_file_enable_tools") {
            output.push_str(&line);
            output.push('\n');
        }
    }

    Ok(output)
}

fn section_entries(source: &str, section: &str) -> Vec<String> {
    let header = format!("[{section}]");
    let mut in_section = false;
    let mut entries = Vec::new();

    for line in source.lines() {
        let trimmed = line.trim();

        if trimmed == header {
            in_section = true;
            continue;
        }

        if in_section && trimmed.starts_with('[') {
            break;
        }

        if in_section && !trimmed.is_empty() && !trimmed.starts_with('#') {
            entries.push(line.to_string());
        }
    }

    entries
}

fn normalize_cross_arch_cargo_tools(tool_lines: &mut Vec<String>, alias_lines: &mut Vec<String>) {
    let mut normalized_tools = Vec::new();
    let mut normalized_aliases = Vec::new();
    let mut has_cargo_binstall = false;

    for line in tool_lines.drain(..) {
        let trimmed = line.trim();
        if trimmed.starts_with("cargo-binstall") {
            has_cargo_binstall = true;
            normalized_tools.push(line);
            continue;
        }

        if let Some((tool_name, version)) = parse_raw_cargo_tool(trimmed) {
            normalized_tools.push(format!("{tool_name} = \"{version}\""));
            normalized_aliases.push(format!("{tool_name} = \"cargo:{tool_name}\""));
            continue;
        }

        normalized_tools.push(line);
    }

    if !has_cargo_binstall {
        let insert_at = normalized_tools
            .iter()
            .position(|line| line.trim_start().starts_with("cargo-"))
            .unwrap_or(normalized_tools.len());
        normalized_tools.insert(insert_at, "cargo-binstall = \"1.20.1\"".to_string());
    }

    normalized_aliases.extend(alias_lines.iter().cloned());
    normalized_aliases.sort();
    normalized_aliases.dedup();

    *tool_lines = normalized_tools;
    *alias_lines = normalized_aliases;
}

fn parse_raw_cargo_tool(line: &str) -> Option<(String, String)> {
    let (key, value) = line.split_once('=')?;
    let tool_name = key
        .trim()
        .strip_prefix("\"cargo:")?
        .strip_suffix('"')?
        .to_string();

    let value = value.trim();
    if let Some(version) = value.strip_prefix('"').and_then(|value| value.strip_suffix('"')) {
        return Some((tool_name, version.to_string()));
    }

    let version = value
        .strip_prefix('{')?
        .strip_suffix('}')?
        .split(',')
        .find_map(|entry| {
            let (key, value) = entry.split_once('=')?;
            (key.trim() == "version")
                .then(|| value.trim().strip_prefix('"')?.strip_suffix('"').map(str::to_string))?
        })?;

    Some((tool_name, version))
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
