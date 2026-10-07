-- app_config.platform: text + CHECK → enum.

CREATE TYPE public.app_platform AS ENUM ('ios', 'android');

ALTER TABLE public.app_config DROP CONSTRAINT app_config_platform_check;
ALTER TABLE public.app_config ALTER COLUMN platform TYPE public.app_platform USING platform::public.app_platform;
