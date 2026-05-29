/**
 * celLanguage — Custom CEL (Common Expression Language) StreamLanguage
 *
 * Provides syntax highlighting for CEL expressions using CodeMirror 6's
 * StreamLanguage parser. Recognises CEL keywords, types, strings, numbers,
 * operators, comments, and identifiers.
 */

import { StreamLanguage } from '@codemirror/language'
import type { StreamParser } from '@codemirror/language'

const celKeywords = new Set([
  'true', 'false', 'null', 'in', 'as', 'not', 'and', 'or',
  'matches', 'contains', 'startsWith', 'endsWith',
])

const celTypes = new Set([
  'int', 'uint', 'double', 'string', 'bytes', 'list', 'map',
  'bool', 'null_type', 'dyn', 'any', 'duration', 'timestamp',
])

const celOperators = [
  '==', '!=', '<=', '>=', '&&', '||',
  '<', '>', '!', '+', '-', '*', '/', '%', '=',
]

/**
 * CodeMirror StreamLanguage parser for CEL expressions.
 * Handles:
 *  - Keywords and types (highlighted distinctly)
 *  - Double-quoted strings with escape sequences
 *  - Numbers (int and float)
 *  - Single-line // comments
 *  - Operators
 *  - Identifiers with dotted paths and bracket indexing
 */
const celParser: StreamParser<unknown> = {
  startState() {
    return {}
  },

  token(stream) {
    // Skip whitespace
    if (stream.eatSpace()) return null

    // Single-line comments
    if (stream.match('//')) {
      stream.skipToEnd()
      return 'comment'
    }

    // Strings (double-quoted with escape sequences)
    if (stream.match('"')) {
      while (!stream.eol()) {
        const next = stream.next()
        if (next === '\\') {
          stream.next() // skip escaped char
        } else if (next === '"') {
          break
        }
      }
      return 'string'
    }

    // Numbers: integers and floats
    if (stream.match(/^-?\d+(\.\d+)?([eE][+-]?\d+)?/)) {
      return 'number'
    }

    // Operators (multi-char first)
    for (const op of celOperators) {
      if (stream.match(op)) {
        return 'operator'
      }
    }

    // Identifiers, keywords, types
    if (stream.match(/^[a-zA-Z_][a-zA-Z0-9_]*/)) {
      const word = stream.current()
      if (celKeywords.has(word)) return 'keyword'
      if (celTypes.has(word)) return 'typeName'
      return 'variable'
    }

    // Dotted paths (continuation after identifier)
    if (stream.match(/^\.[a-zA-Z_][a-zA-Z0-9_]*/)) {
      return 'property'
    }

    // Brackets and parentheses
    if (stream.match(/^[[\](){}]/)) {
      return 'bracket'
    }

    // Skip unknown characters
    stream.next()
    return null
  },
}

/** CEL language support for CodeMirror 6 */
export const celLanguage = StreamLanguage.define(celParser)
