CREATE OR REPLACE FUNCTION api.quick_link(url TEXT, alias TEXT, api_key TEXT DEFAULT NULL)
RETURNS JSON AS $$
BEGIN
  RETURN api.create_short_link(url, alias);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER; 