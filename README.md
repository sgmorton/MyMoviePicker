# Movie Picker

A Flutter-based web application for browsing and selecting movies from a DVDProfiler XML export.

## Features

- **XML Parsing:** Reads and displays your movie collection from a `collection.xml` file.
- **Drag & Drop:** Easily load your XML file and any local cover art images by dragging them onto the window.
- **Web Scraping:** Automatically fetches missing cover art, movie summaries, and Rotten Tomatoes scores from TMDB, iTunes, and OMDb.
- **Rich UI:**
  - Sleek, modern dark theme.
  - Advanced filtering by title, genre, and media type (4K, Blu-ray, DVD, 3D).
  - Sort by Collection Number, Title, Year, and more.
  - "Surprise Me!" button for a random pick from your entire collection.
- **"What are we watching?" Panel:**
  - Add up to 10 movies to a selection queue.
  - "Random Choice" button to pick a winner from your queue.
  - Clear the queue to start over.
- **Persistence:** Your collection, fetched images, and API keys are saved locally in your browser, so your data is ready for you the next time you open the app.

## Setup

1.  **Get Dependencies:**
    ```shell
    flutter pub get
    ```
2.  **API Keys:**
    This app uses The Movie Database (TMDB) and the Open Movie Database (OMDb) to fetch movie details. You will need to obtain free API keys from both services.

    - [Get a TMDB API Key](https://www.themoviedb.org/signup)
    - [Get an OMDb API Key](http://www.omdbapi.com/apikey.aspx)

    Once you have your keys, run the app and click the **Settings** icon in the top-right corner to enter and save them.

## Running the App

Run the following command from the project root:

```shell
flutter run -d chrome
```

## Usage

Once the app is running, simply drag and drop your DVDProfiler `collection.xml` file (and any associated cover art image files) onto the main window to load your collection.
