CREATE OR REPLACE FUNCTION api.get_original_url(p_code TEXT)
RETURNS JSON AS $$
DECLARE
  v_original_url TEXT;
BEGIN
  SELECT u.original_url INTO v_original_url
  FROM api.short_links s
  JOIN api.urls u ON s.url_id = u.id
  WHERE s.code = p_code;
  
  IF v_original_url IS NULL THEN
    RETURN json_build_object(
      'success', FALSE,
      'error', 'Short URL not found'
    );
  END IF;
  
  RETURN json_build_object(
    'success', TRUE,
    'original_url', v_original_url
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER; 