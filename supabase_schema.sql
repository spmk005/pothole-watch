-- Profiles table setup (Optional, if not already configured)
CREATE TABLE public.profiles (
  id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Turn on Row Level Security (RLS) for profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Allow users to view their own profile
CREATE POLICY "Users can view their own profile"
  ON public.profiles FOR SELECT
  USING ( auth.uid() = id );

-- Allow users to insert their own profile
CREATE POLICY "Users can insert their own profile"
  ON public.profiles FOR INSERT
  WITH CHECK ( auth.uid() = id );


-- Potholes table setup
CREATE TABLE public.potholes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  lat DOUBLE PRECISION NOT NULL,
  lng DOUBLE PRECISION NOT NULL,
  image_url TEXT,
  description TEXT,
  status TEXT DEFAULT 'reported',
  severity TEXT DEFAULT 'Medium',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Turn on Row Level Security (RLS) for potholes
ALTER TABLE public.potholes ENABLE ROW LEVEL SECURITY;

-- Allow anyone (or authenticated users) to view all potholes on the map
CREATE POLICY "Anyone can view potholes"
  ON public.potholes FOR SELECT
  USING ( true );

-- Allow users to insert new potholes linked to their own user_id
CREATE POLICY "Users can insert potholes"
  ON public.potholes FOR INSERT
  WITH CHECK ( auth.uid() = user_id );


-- Storage bucket setup for Pothole Images (if using Supabase Storage instead of Firebase)
INSERT INTO storage.buckets (id, name, public) 
VALUES ('pothole_images', 'pothole_images', true);

-- Allow authenticated users to upload images
CREATE POLICY "Authenticated users can upload images"
ON storage.objects FOR INSERT TO authenticated WITH CHECK (
  bucket_id = 'pothole_images'
);

-- Allow anyone to view images
CREATE POLICY "Anyone can read images"
ON storage.objects FOR SELECT 
USING ( bucket_id = 'pothole_images' );
