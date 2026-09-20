import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';

class ChatMessageData {
  final int? id;
  final String text;
  final bool isUser;
  final String type;
  final String? imagePath;
  final String? toolName;
  final DateTime timestamp;

  ChatMessageData({
    this.id,
    required this.text,
    required this.isUser,
    this.type = 'text',
    this.imagePath,
    this.toolName,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'text': text,
      'is_user': isUser ? 1 : 0,
      'type': type,
      'image_path': imagePath,
      'tool_name': toolName,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  factory ChatMessageData.fromMap(Map<String, dynamic> map) {
    return ChatMessageData(
      id: map['id'],
      text: map['text'],
      isUser: map['is_user'] == 1,
      type: map['type'] ?? 'text',
      imagePath: map['image_path'],
      toolName: map['tool_name'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
    );
  }
}

class ChatDatabaseService {
  static final ChatDatabaseService _instance = ChatDatabaseService._internal();
  factory ChatDatabaseService() => _instance;
  ChatDatabaseService._internal();

  static const int _maxMessages = 1000;

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = join(directory.path, 'chat.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        is_user INTEGER NOT NULL,
        type TEXT DEFAULT 'text',
        image_path TEXT,
        tool_name TEXT,
        timestamp INTEGER NOT NULL
      )
    ''');
  }

  Future<int> insertMessage(ChatMessageData message) async {
    final db = await database;
    final id = await db.insert('messages', message.toMap());
    await _cleanupOldMessages();
    return id;
  }

  Future<void> _cleanupOldMessages() async {
    final db = await database;
    await db.rawDelete('''
      DELETE FROM messages WHERE id NOT IN (
        SELECT id FROM messages ORDER BY timestamp DESC LIMIT ?
      )
    ''', [_maxMessages]);
  }

  Future<List<ChatMessageData>> getMessages({int limit = 100}) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      orderBy: 'timestamp DESC',
      limit: limit,
    );

    return maps.reversed.map((map) => ChatMessageData.fromMap(map)).toList();
  }

  Future<List<ChatMessageData>> getLastNMessages(int n) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.rawQuery(
      'SELECT * FROM messages ORDER BY timestamp DESC LIMIT ?',
      [n],
    );

    return maps.reversed.map((map) => ChatMessageData.fromMap(map)).toList();
  }

  Future<void> clearAllMessages() async {
    final db = await database;
    await db.delete('messages');
  }

  Future<void> deleteMessage(int id) async {
    final db = await database;
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> getMessageCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM messages');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getMaxMessages() async => _maxMessages;

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
