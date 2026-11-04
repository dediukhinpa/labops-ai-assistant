import { isObject, type JsonObject } from './json-leaves';
import type { Restorer } from './restorer';

/**
 * Восстановить нестриминговый ответ: text и аргументы tool_use. Блоки thinking не трогаются.
 * @returns изменённый объект ответа.
 */
export async function restoreMessageJson(
  body: JsonObject,
  restorer: Restorer,
): Promise<JsonObject> {
  const content = body.content;
  if (!Array.isArray(content)) return body;
  for (const block of content) {
    if (!isObject(block)) continue;
    if (block.type === 'text' && typeof block.text === 'string') {
      block.text = await restorer.text(block.text);
    } else if (typeof block.type === 'string' && block.type.endsWith('tool_use')) {
      await restorer.leaves(block.input);
    }
  }
  return body;
}
