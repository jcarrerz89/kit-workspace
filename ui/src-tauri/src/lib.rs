use std::process::Command;
use serde::Serialize;

#[derive(Serialize)]
pub struct CommandResult {
    pub stdout:  String,
    pub stderr:  String,
    pub success: bool,
}

/// Run the kit-workspace bash script with the given args.
/// On Windows, executes via bash (WSL/Git Bash must be on PATH).
#[tauri::command]
fn run_kit_command(kws_path: String, args: Vec<String>) -> CommandResult {
    #[cfg(target_os = "windows")]
    let result = Command::new("bash").arg(&kws_path).args(&args).output();

    #[cfg(not(target_os = "windows"))]
    let result = Command::new("bash").arg(&kws_path).args(&args).output();

    match result {
        Ok(out) => CommandResult {
            stdout:  String::from_utf8_lossy(&out.stdout).into_owned(),
            stderr:  String::from_utf8_lossy(&out.stderr).into_owned(),
            success: out.status.success(),
        },
        Err(e) => CommandResult {
            stdout:  String::new(),
            stderr:  e.to_string(),
            success: false,
        },
    }
}

/// Read a file from disk and return its contents as a string.
#[tauri::command]
fn read_file(path: String) -> Result<String, String> {
    std::fs::read_to_string(&path).map_err(|e| e.to_string())
}

/// List entries in a directory (names only, sorted).
#[tauri::command]
fn list_dir(path: String) -> Result<Vec<String>, String> {
    let rd = std::fs::read_dir(&path).map_err(|e| e.to_string())?;
    let mut names: Vec<String> = rd
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    Ok(names)
}

/// Write content to a file, creating parent directories as needed.
#[tauri::command]
fn write_file(path: String, content: String) -> Result<(), String> {
    if let Some(parent) = std::path::Path::new(&path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&path, content).map_err(|e| e.to_string())
}

/// Return the current user's home directory.
#[tauri::command]
fn home_dir() -> String {
    dirs::home_dir()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            run_kit_command,
            read_file,
            write_file,
            list_dir,
            home_dir,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
