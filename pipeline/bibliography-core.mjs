export const normalizeBibliographyText = value => String(value || '').normalize('NFKC').toLowerCase().replace(/&amp;/g, 'and').replace(/[^\p{L}\p{N}]/gu, '');
export const cleanAuthorName = value => String(value || '').replace(/[†‡*]+/g, '').replace(/\s+/g, ' ').trim();
export const extractDoi = value => decodeURIComponent(String(value || '')).match(/10\.\d{4,9}\/[^?#\s/]+(?:\/[^?#\s]+)*/i)?.[0]?.replace(/[),.;]+$/, '').toLowerCase() || null;
export function extractAuthorRoles(raw) {
  const parts = String(raw || '').split(/,|\band\b/).map(x => x.trim()).filter(Boolean);
  return {
    corresponding: parts.filter(x => x.includes('*')).map(cleanAuthorName).filter(Boolean),
    coFirst: parts.filter(x => /[†‡]/.test(x)).map(cleanAuthorName).filter(Boolean),
  };
}
