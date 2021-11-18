FileWriteFlush(File, Line)
{
	File.WriteLine(Line)
	File.Read(0)
}

global status_line
WriteStatus(Status, Important=1)
{
	if (status_file)
	{
		if (!Important && Status == status_line)
			return

		FileWriteFlush(status_file, "status=" . Status)
		status_line := Status
	}
	else if (Important)
		MsgBox % "Status update: " . Status
}

WriteSuccess()
{
	if (status_file)
		FileWriteFlush(status_file, "success=OK")
	else
		MsgBox % "Success"
	Exit 0
}

WriteProcessFailure(Status, NonFatal=0)
{
	if (status_file)
		FileWriteFlush(status_file, "fail=process=" . Status)
	else
		MsgBox % "Failure (process): " . Status
	if (NonFatal = 0)
		Exit 1
}

WriteEnvironmentFailure(Status, NonFatal=0)
{
	if (status_file)
		FileWriteFlush(status_file, "fail=environment=" . Status)
	else
		MsgBox % "Failure (environment): " . Status
	if (NonFatal = 0)
		Exit 1
}

WriteLogicFailure(Status)
{
	if (status_file)
		FileWriteFlush(status_file, "fail=logic=" . Status)
	else
		MsgBox % "Failure (logic error): " . Status
	Exit 1
}

StrJoin(Array, Delimiter)
{
	result := ""
	for i, v in Array
	{
		if (i == 1)
			result := Format("{}", v)
		else
			result := result . Delimiter . Format("{}", v)
	}
	return result
}

Basename(FileName)
{
	SplitPath, % FileName, FileBase, FileDir
	return FileBase
}

KillConsolidate(ExitReason, ExitCode)
{
	Loop {
		WinKill, ahk_exe consolidate.exe,, 5
		Process, Close, consolidate.exe
		Process, Exist, consolidate.exe
		if (ErrorLevel == 0)
			break
		Sleep, 100
	}
}

CheckWindowActive(Ids)
{
	id := WinExist("A")
	for i, v in Ids
	{
		if (id == v)
			return
	}
	WriteEnvironmentFailure("unexpected window " . id . " is active (expected one of " . StrJoin(Ids, ", ") . ")")
}

;
; start
;

DllCall("AllocConsole")
global stdout
stdout := FileOpen("*", "w `n")
global stderr
stderr := FileOpen("**", "w `n")
global status_file

;if (A_Args.Length() == 0)
;{
;	from_file := "\\stratofortress.nexus.i.intelfx.name\SmbBackup\13801F63CD94DFCF-00-00.mrimg"
;	to_file := "\\stratofortress.nexus.i.intelfx.name\SmbBackup\13801F63CD94DFCF-86-86.mrimg"
;	status_file := ""
;}
;else
if (A_Args.Length() == 2)
{
	from_file := A_Args[1]
	to_file := A_Args[2]
	status_file := ""
}
else if (A_Args.Length() == 3)
{
	from_file := A_Args[1]
	to_file := A_Args[2]
	status_file := FileOpen(A_Args[3], "w")
}
else
{
	stdout.Write("Expected 2 or 3 arguments, got " . A_Args.Length() . "`r`n")
	stdout.Write("Usage: consolidate.ahk input output [log]`r`n")
	Exit 1
}

;
; open or find window
;


;WinWait, ahk_exe consolidate.exe,, 1
;if not ErrorLevel
;{
;	id := WinExist()
;}
;else
;{
;	OnExit("KillConsolidate", 1)
;	Run "consolidate.exe"
;	WinWait, ahk_exe consolidate.exe,, 5
;	if (ErrorLevel)
;		WriteEnvironmentFailure("consolidate.exe could not start")
;}

KillConsolidate(0, 0)
OnExit("KillConsolidate", 1)
Run "consolidate.exe"
WinWait, ahk_exe consolidate.exe,, 5
if (ErrorLevel)
	WriteEnvironmentFailure("consolidate.exe could not start")

id := WinExist()
if (id = 0)
	WriteEnvironmentFailure("consolidate.exe could not start")
WinActivate, ahk_id %id%
SetControlDelay -1

status_last := ""


LoadFile(Id, Button, Edit, FileName, NonFatal=0)
{
	FileBase := Basename(FileName)

	WinActivate, ahk_id %Id%
	ControlSetText, Static3,, ahk_id %Id%
	ControlSetText, %Edit%,, ahk_id %Id%
	
	ControlClick, %Button%, ahk_id %Id%
	WinWaitActive, Open,, 5
	if (ErrorLevel)
		WriteEnvironmentFailure("could not reach Open dialog")
	open_id := WinExist()
	
	ids := []
	ids.Push(Id)
	ids.Push(open_id)

	ControlSetText, Edit1, %FileName%, ahk_id %open_id%
	ControlClick, Button1, ahk_id %open_id%
	
	i := 0
	Loop {
		CheckWindowActive(ids)
		if (i > 60)
			WriteEnvironmentFailure("could not load file in time")
		Sleep, 1000
		i := i + 1

		ControlGetText, status, %Edit%, ahk_id %Id%
		if (status == "")
			continue
		else if (status == FileName)
			break
		else
			WriteLogicFailure("unexpected edit field status: " . status)
	}
	
	i := 0
	Loop {
		CheckWindowActive(ids)
		if (i > 60)
			WriteEnvironmentFailure("could not load file in time")
		Sleep, 1000
		i := i + 1
		
		ControlGetText, status, Static3, ahk_id %Id%
		if (status == "")
			continue
		else if (status == "File '" . FileBase . "' loaded OK")
		{
			WriteStatus("loaded " . FileBase)
			return "ok"
		}
		else if (status == "The system cannot find the file specified.")
			WriteEnvironmentFailure("could not find file")
		else if (status == "Error - Unable to load image file")
		{
			WriteProcessFailure("could not load file", NonFatal)
			return "fail"
		}
		else
			WriteLogicFailure("unexpected status: " . status)
	}
}

;
; open files, attempt "recovery" if last consolidation was aborted
;

s := LoadFile(id, "Button1", "Edit1", from_file, 1)
if (s == "ok")
{
	LoadFile(id, "Button2", "Edit2", to_file)
}
else if (s == "fail")
{
	WriteStatus("attempting recovery")
	LoadFile(id, "Button2", "Edit2", to_file)
	LoadFile(id, "Button1", "Edit1", from_file)
}
else
	WriteLogicFailure("unexpected return: " . s)

;
; consolidate
;

;MsgBox % "Ready to consolidate"

WinActivate, ahk_id %Id%
ControlSetText, Static3,, ahk_id %Id%
ControlClick, Button4, ahk_id %id%

Loop {
	Sleep, 1000
	ControlGetText, status, Static3, ahk_id %Id%
	if (status == "")
		continue
	else if (status == "Please Wait...")
		WriteStatus("waiting", 0)
	else if (status == "Cancelling please Wait...")
		WriteStatus("waiting", 0)
	else if (status == "Begin consolidation")
		WriteStatus("starting", 0)
	else if (status ~= "^Current Progress:  ([0-9]{1,3})%$")
	{
		RegExMatch(status, "O)^Current Progress:  ([0-9]{1,3})%$", match)
		WriteStatus("progress=" . match.Value(1), 0)
	}
	else if (status == "Success")
		WriteSuccess()
	else if (status == "Cancelled")
		WriteProcessFailure("cancelled")
	else if (status ~= "^Failed - .*")
		WriteProcessFailure("consolidation failure: " . status)
	else
		WriteLogicFailure("unexpected status: " . status)
}

WriteSuccess()
