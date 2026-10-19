import Foundation
import MCP

// MARK: - The seven tools, as the assistant sees them
//
// Names, descriptions and schemas. All read-only: the annotations say so, and the
// app answers nothing else. The app (ClaudeTools.swift) parses the same argument
// names; the answers below are what it returns, as structured content and as the
// same JSON in text.

enum ToolCatalog {
    static let tools: [Tool] = definitions.map { d in
        Tool(name: d.name, title: d.title, description: d.description, inputSchema: schema(d.input),
             annotations: .init(title: d.title, readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
             outputSchema: schema(d.output))
    }

    private struct Definition {
        let name: String
        let title: String
        let description: String
        let input: String
        let output: String
    }

    private static func schema(_ json: String) -> Value {
        (try? JSONDecoder().decode(Value.self, from: Data(json.utf8))) ?? .object(["type": "object"])
    }

    // Pieces shared by several schemas.
    private static let meetingRef = """
        {"type": "object", "description": "The meeting it belongs to.", "properties": {
          "id": {"type": "string"}, "title": {"type": "string"}, "date": {"type": "string", "description": "ISO 8601 start of the meeting."}}}
        """
    private static let from = "\"from\": {\"type\": \"string\", \"description\": \"Only from this date or moment on, ISO 8601 (2026-10-01 or 2026-10-01T09:00:00+02:00).\"}"
    private static let to = "\"to\": {\"type\": \"string\", \"description\": \"Only up to this date or moment, ISO 8601. A bare date includes the whole day.\"}"
    private static let folderID = "\"folder_id\": {\"type\": \"string\", \"description\": \"Only meetings in this folder (from mindtalk_list_folders).\"}"
    private static let cursor = "\"cursor\": {\"type\": \"string\", \"description\": \"The nextCursor from the previous page.\"}"
    private static let nextCursor = "\"nextCursor\": {\"type\": \"string\", \"description\": \"Present when there is another page.\"}, \"note\": {\"type\": \"string\"}"

    private static let definitions: [Definition] = [
        Definition(
            name: "mindtalk_list_folders",
            title: "List folders",
            description: "The folders the user shares with their assistant, with how many meetings each holds. Folders kept private are not listed. Use a folder's id as folder_id in the other tools.",
            input: """
                {"type": "object", "properties": {}, "additionalProperties": false}
                """,
            output: """
                {"type": "object", "properties": {
                  "folders": {"type": "array", "items": {"type": "object", "properties": {
                    "id": {"type": "string"}, "name": {"type": "string"}, "meeting_count": {"type": "integer"}}}},
                  "meetings_without_folder": {"type": "integer"}}}
                """),
        Definition(
            name: "mindtalk_list_meetings",
            title: "List meetings",
            description: "Meetings the user shares, newest first: title, start, length, folder, who spoke, and one line about what it was about. Narrow by folder, dates or a query (every word must occur somewhere in the meeting). Paged: follow nextCursor.",
            input: """
                {"type": "object", "properties": {
                  \(folderID), \(from), \(to),
                  "query": {"type": "string", "description": "Words that must all occur in the meeting (title, summary, notes or transcript)."},
                  "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 20},
                  \(cursor)}, "additionalProperties": false}
                """,
            output: """
                {"type": "object", "properties": {
                  "meetings": {"type": "array", "items": {"type": "object", "properties": {
                    "id": {"type": "string"}, "title": {"type": "string"}, "start": {"type": "string"},
                    "duration_seconds": {"type": "integer"},
                    "folder": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}}},
                    "speakers": {"type": "array", "items": {"type": "string"}},
                    "gist": {"type": "string"}, "has_summary": {"type": "boolean"}, "has_transcript": {"type": "boolean"},
                    "link": {"type": "string"}}}},
                  "total": {"type": "integer"}, \(nextCursor)}}
                """),
        Definition(
            name: "mindtalk_get_meeting",
            title: "Get a meeting's notes",
            description: "One meeting's summary: overview, decisions, tasks (with owner and done), the user's own notes and the moments they marked, each with its time and link where known. Never the transcript: use mindtalk_get_transcript for that. response_format detailed adds the summary's points and a link per item.",
            input: """
                {"type": "object", "properties": {
                  "meeting_id": {"type": "string"},
                  "include": {"type": "array", "items": {"type": "string", "enum": ["summary", "decisions", "tasks", "notes", "marks"]},
                    "description": "Which parts to return. Default: all."},
                  "response_format": {"type": "string", "enum": ["concise", "detailed"], "default": "concise"}},
                  "required": ["meeting_id"], "additionalProperties": false}
                """,
            output: """
                {"type": "object", "properties": {
                  "id": {"type": "string"}, "title": {"type": "string"}, "date": {"type": "string"}, "start": {"type": "string"},
                  "duration_seconds": {"type": "integer"},
                  "folder": {"type": "object", "properties": {"id": {"type": "string"}, "name": {"type": "string"}}},
                  "speakers": {"type": "array", "items": {"type": "string"}}, "link": {"type": "string"},
                  "gist": {"type": "string"}, "has_summary": {"type": "boolean"}, "has_transcript": {"type": "boolean"},
                  "summary": {"type": ["object", "null"], "properties": {"overview": {"type": "string"}, "written": {"type": "string"},
                    "written_by": {"type": "string"}, "notes_changed_since": {"type": "boolean"},
                    "points": {"type": "array", "items": {"type": "object"}}}},
                  "decisions": {"type": "array", "items": {"type": "object", "properties": {
                    "text": {"type": "string"}, "t_seconds": {"type": "integer"}, "time": {"type": "string"}, "link": {"type": "string"}}}},
                  "tasks": {"type": "array", "items": {"type": "object", "properties": {
                    "text": {"type": "string"}, "owner": {"type": "string"}, "done": {"type": "boolean"},
                    "t_seconds": {"type": "integer"}, "time": {"type": "string"}, "link": {"type": "string"}}}},
                  "notes": {"type": "array", "items": {"type": "object", "properties": {
                    "text": {"type": "string"}, "t_seconds": {"type": "integer"}, "time": {"type": "string"}, "link": {"type": "string"}}}},
                  "marks": {"type": "array", "items": {"type": "object", "properties": {
                    "kind": {"type": "string", "enum": ["decision", "task", "important"]}, "text": {"type": "string"},
                    "t_seconds": {"type": "integer"}, "time": {"type": "string"}, "link": {"type": "string"}}}},
                  "note": {"type": "string"}}}
                """),
        Definition(
            name: "mindtalk_get_transcript",
            title: "Get a transcript",
            description: "What was said in one meeting, as lines \"[mm:ss] Speaker: text\", about 25 000 characters per page; follow nextCursor for the rest. Narrow with start_sec/end_sec or a speaker's name. Only when the user shares whole transcripts. Prefer mindtalk_search to find the passage you need.",
            input: """
                {"type": "object", "properties": {
                  "meeting_id": {"type": "string"},
                  "start_sec": {"type": "number", "description": "Only lines from this second on."},
                  "end_sec": {"type": "number", "description": "Only lines up to this second."},
                  "speaker": {"type": "string", "description": "Only this speaker's lines (part of the name is enough)."},
                  \(cursor)}, "required": ["meeting_id"], "additionalProperties": false}
                """,
            output: """
                {"type": "object", "properties": {
                  "meeting": \(meetingRef),
                  "segments": {"type": "array", "items": {"type": "string"}, "description": "Lines \\"[mm:ss] Speaker: text\\"."},
                  "from_seconds": {"type": "integer"}, "to_seconds": {"type": "integer"},
                  "total_seconds": {"type": "integer"}, "total_chars": {"type": "integer"}, "total_segments": {"type": "integer"},
                  "link": {"type": "string"}, \(nextCursor)}}
                """),
        Definition(
            name: "mindtalk_search",
            title: "Search",
            description: "Finds where words occur: in thoughts, in meetings' summaries, decisions, tasks and notes, and in what was said (when transcripts are shared). Every word must occur in the meeting; each hit is a short excerpt with the meeting, the moment (t_seconds), the speaker and a link. Scope: one meeting (meeting_id), a folder (folder_id), or everything shared.",
            input: """
                {"type": "object", "properties": {
                  "query": {"type": "string", "description": "One or more words. Case does not matter; å, ä and ö do."},
                  "meeting_id": {"type": "string", "description": "Only this meeting."},
                  \(folderID),
                  "kinds": {"type": "array", "items": {"type": "string", "enum": ["thoughts", "summaries", "transcripts"]},
                    "description": "Where to look. Default: everything the user shares."},
                  \(from), \(to),
                  "limit": {"type": "integer", "minimum": 1, "maximum": 50, "default": 20}},
                  "required": ["query"], "additionalProperties": false}
                """,
            output: """
                {"type": "object", "properties": {
                  "hits": {"type": "array", "items": {"type": "object", "properties": {
                    "kind": {"type": "string", "enum": ["thought", "summary", "transcript"]},
                    "part": {"type": "string", "description": "For summary hits: title, overview, decision, task, point, note or mark."},
                    "text": {"type": "string"}, "id": {"type": "string"}, "date": {"type": "string"},
                    "meeting": \(meetingRef),
                    "t_seconds": {"type": "integer"}, "speaker": {"type": "string"}, "link": {"type": "string"}}}},
                  "total": {"type": "integer"}, "note": {"type": "string"}}}
                """),
        Definition(
            name: "mindtalk_list_tasks",
            title: "List tasks",
            description: "Tasks from the meetings' summaries, and moments the user marked as tasks: what, who, whether it is done, in which meeting and at what moment. Open ones by default; narrow by folder, dates or owner. Paged: follow nextCursor.",
            input: """
                {"type": "object", "properties": {
                  "status": {"type": "string", "enum": ["open", "done", "all"], "default": "open"},
                  \(folderID), \(from), \(to),
                  "owner": {"type": "string", "description": "Only tasks whose owner contains this name."},
                  "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 50},
                  \(cursor)}, "additionalProperties": false}
                """,
            output: """
                {"type": "object", "properties": {
                  "tasks": {"type": "array", "items": {"type": "object", "properties": {
                    "task": {"type": "string"}, "owner": {"type": "string"}, "done": {"type": "boolean"},
                    "meeting": \(meetingRef), "t_seconds": {"type": "integer"}, "link": {"type": "string"}}}},
                  "total": {"type": "integer"}, \(nextCursor)}}
                """),
        Definition(
            name: "mindtalk_list_thoughts",
            title: "List thoughts",
            description: "The user's thoughts (short spoken notes, \"Tankar\"), newest first, with date, done and pinned. Narrow by dates or words. Paged: follow nextCursor.",
            input: """
                {"type": "object", "properties": {
                  \(from), \(to),
                  "query": {"type": "string", "description": "Words that must all occur in the thought."},
                  "limit": {"type": "integer", "minimum": 1, "maximum": 200, "default": 50},
                  \(cursor)}, "additionalProperties": false}
                """,
            output: """
                {"type": "object", "properties": {
                  "thoughts": {"type": "array", "items": {"type": "object", "properties": {
                    "id": {"type": "string"}, "text": {"type": "string"}, "date": {"type": "string"},
                    "done": {"type": "boolean"}, "pinned": {"type": "boolean"}, "link": {"type": "string"}}}},
                  "total": {"type": "integer"}, \(nextCursor)}}
                """),
    ]
}
