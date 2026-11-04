import { ATTACHMENT_STRIPPED_TEXT, STATUS_PII_FOUND } from './constants';
import type { ImagePolicy } from './config';
import { RequestRejectedError } from './errors';
import { collectStringLeaves, isObject, type JsonObject, type Leaf } from './json-leaves';

/** Блоки, которые не трогаем: подпись thinking, служебные результаты сервера. */
const PASSTHROUGH_BLOCKS: ReadonlySet<string> = new Set([
  'thinking',
  'redacted_thinking',
  'web_search_tool_result',
  'web_fetch_tool_result',
  'code_execution_tool_result',
  'compaction',
  // Определение инструмента, подгруженное по ходу сессии (сообщение роли system): то же, что
  // массив tools, который не маскируется; ПДн в описаниях инструментов не бывает.
  'tool_addition',
]);
/** Блоки с аргументами инструмента: маскируются все строковые листья input. */
const TOOL_INPUT_BLOCKS: ReadonlySet<string> = new Set([
  'tool_use',
  'server_tool_use',
  'mcp_tool_use',
]);
/** Блоки с содержимым-результатом (строка или список блоков). */
const RESULT_BLOCKS: ReadonlySet<string> = new Set(['tool_result', 'mcp_tool_result']);

/**
 * Обходит запрос в фиксированном порядке (system, затем messages по порядку) и собирает
 * строковые листья, которые надо маскировать. Вложения заменяются по политике.
 * Порядок обхода определяет нумерацию токенов, поэтому менять его нельзя.
 */
export class RequestWalker {
  readonly leaves: Leaf[] = [];
  /** Сколько вложений заменено заглушкой. */
  strippedAttachments = 0;
  /** Сколько вложений ушло как есть (политика passthrough). */
  passedAttachments = 0;

  constructor(private readonly imagePolicy: ImagePolicy) {}

  /** Обойти тело запроса /v1/messages (или count_tokens). */
  walk(body: JsonObject): void {
    const system = body.system;
    if (typeof system === 'string') this.addString(body, 'system', system);
    else if (Array.isArray(system)) this.walkBlocks(system);
    const messages = body.messages;
    if (!Array.isArray(messages)) return;
    for (const message of messages) {
      if (!isObject(message)) continue;
      const content = message.content;
      if (typeof content === 'string') this.addString(message, 'content', content);
      else if (Array.isArray(content)) this.walkBlocks(content);
    }
  }

  private addString(holder: JsonObject, key: string, text: string): void {
    if (text !== '') this.leaves.push({ holder, key, text });
  }

  private walkBlocks(blocks: unknown[]): void {
    for (let i = 0; i < blocks.length; i++) {
      const block = blocks[i];
      if (!isObject(block)) continue;
      this.walkBlock(blocks, i, block);
    }
  }

  private walkBlock(parent: unknown[], index: number, block: JsonObject): void {
    const type = block.type;
    if (typeof type !== 'string') throw rejectUnknown('без типа');
    if (PASSTHROUGH_BLOCKS.has(type)) return;
    if (type === 'text') {
      if (typeof block.text === 'string') this.addString(block, 'text', block.text);
    } else if (type === 'image') {
      this.attachment(parent, index, block);
    } else if (type === 'document') {
      this.walkDocument(parent, index, block);
    } else if (TOOL_INPUT_BLOCKS.has(type)) {
      collectStringLeaves(block.input, this.leaves);
    } else if (RESULT_BLOCKS.has(type)) {
      this.walkContent(block);
    } else if (type === 'search_result') {
      this.walkContent(block);
      if (typeof block.title === 'string') this.addString(block, 'title', block.title);
    } else {
      throw rejectUnknown(type);
    }
  }

  /** content блока: строка или список блоков. */
  private walkContent(block: JsonObject): void {
    const content = block.content;
    if (typeof content === 'string') this.addString(block, 'content', content);
    else if (Array.isArray(content)) this.walkBlocks(content);
  }

  private walkDocument(parent: unknown[], index: number, block: JsonObject): void {
    const source = block.source;
    const kind = isObject(source) ? source.type : undefined;
    if (isObject(source) && kind === 'text' && typeof source.data === 'string') {
      this.addString(source, 'data', source.data);
    } else if (isObject(source) && kind === 'content') {
      this.walkContent(source);
    } else if (!this.attachment(parent, index, block)) {
      return; // заглушка вместо документа: подписи заменены вместе с ним
    }
    if (typeof block.title === 'string') this.addString(block, 'title', block.title);
    if (typeof block.context === 'string') this.addString(block, 'context', block.context);
  }

  /**
   * Вложение без текста (изображение, PDF) по политике.
   * @returns true, если блок остался на месте (passthrough) и его подписи надо маскировать.
   */
  private attachment(parent: unknown[], index: number, block: JsonObject): boolean {
    if (this.imagePolicy === 'passthrough') {
      this.passedAttachments++;
      return true;
    }
    if (this.imagePolicy === 'reject') {
      throw new RequestRejectedError(
        STATUS_PII_FOUND,
        'Вложения (изображения, PDF) пока нельзя отправлять модели: маскирование не включено.',
        'attachment_rejected',
      );
    }
    const stub: JsonObject = { type: 'text', text: ATTACHMENT_STRIPPED_TEXT };
    if (block.cache_control !== undefined) stub.cache_control = block.cache_control;
    parent[index] = stub;
    this.strippedAttachments++;
    return false;
  }
}

function rejectUnknown(type: string): RequestRejectedError {
  return new RequestRejectedError(
    STATUS_PII_FOUND,
    'Неизвестный тип блока в запросе: проверить на ПДн нельзя, запрос не отправлен.',
    `unknown_block_${type.slice(0, 40)}`,
  );
}
