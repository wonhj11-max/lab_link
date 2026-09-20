import { createClient } from '@supabase/supabase-js';
const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;
export const db = url && key ? createClient(url, key) : null;
export function errorMessage(error: unknown): string {
 const message = typeof error === 'object' && error && 'message' in error ? String(error.message) : String(error);
 if (/schema cache|does not exist|Could not find the table/.test(message)) return '데이터베이스 초기 설정이 필요합니다. 연구실 데이터는 아직 공개되지 않았습니다.';
 if (/fetch|network/i.test(message)) return '연결이 원활하지 않습니다. 잠시 후 다시 시도해 주세요.';
 if (/Invalid login/.test(message)) return '이메일 또는 비밀번호를 확인해 주세요.';
 return message;
}
