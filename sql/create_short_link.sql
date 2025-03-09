CREATE OR REPLACE FUNCTION api.create_short_link(p_original_url TEXT, p_custom_alias TEXT DEFAULT NULL)
RETURNS JSON AS $$
DECLARE
  v_url_id INTEGER;
  v_code TEXT;
BEGIN
  INSERT INTO api.urls (original_url) VALUES (p_original_url) RETURNING id INTO v_url_id;
  v_code := COALESCE(p_custom_alias, 'url' || v_url_id::TEXT);
  INSERT INTO api.short_links (url_id, code) VALUES (v_url_id, v_code);
  RETURN json_build_object(
    'success', TRUE,
    'code', v_code,
    'short_url', 'https://ref.menezmethod.com/r/' || v_code,
    'original_url', p_original_url
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER; 