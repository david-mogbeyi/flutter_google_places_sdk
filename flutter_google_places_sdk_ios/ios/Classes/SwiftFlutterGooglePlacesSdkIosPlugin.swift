import Flutter
import UIKit
import GooglePlaces

private let ALL_PLACE_FIELDS: [String] = [
    "ADDRESS", "ADDRESS_COMPONENTS", "BUSINESS_STATUS", "ID", "LAT_LNG", "NAME",
    "OPENING_HOURS", "PHONE_NUMBER", "PHOTO_METADATAS", "PLUS_CODE", "PRICE_LEVEL",
    "RATING", "TYPES", "USER_RATINGS_TOTAL", "UTC_OFFSET", "VIEWPORT", "WEBSITE_URI",
]

public class SwiftFlutterGooglePlacesSdkIosPlugin: NSObject, FlutterPlugin {
    static let CHANNEL_NAME = "plugins.msh.com/flutter_google_places_sdk"
    let METHOD_INITIALIZE = "initialize"
    let METHOD_DEINITIALIZE = "deinitialize"
    let METHOD_IS_INITIALIZE = "isInitialized"
    let METHOD_FIND_AUTOCOMPLETE_PREDICTIONS = "findAutocompletePredictions"
    let METHOD_FETCH_PLACE = "fetchPlace"
    let METHOD_FETCH_PLACE_PHOTO = "fetchPlacePhoto"
    
    private var placesClient: GMSPlacesClient!
    private var lastSessionToken: GMSAutocompleteSessionToken?
    
    private var photosCache: Dictionary<String, GMSPlacePhotoMetadata> = [:]
    private var runningUid: Int = 1

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: CHANNEL_NAME, binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterGooglePlacesSdkIosPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case METHOD_INITIALIZE:
            let args = call.arguments as? Dictionary<String,Any>
            let apiKey = args?["apiKey"] as! String?
            // we can't do anything with the locale so no need to read it
            initialize(apiKey: apiKey)
            result(nil)
        case METHOD_DEINITIALIZE:
            // nothing to do
            result(nil)
        case METHOD_IS_INITIALIZE:
            result(placesClient != nil)
        case METHOD_FIND_AUTOCOMPLETE_PREDICTIONS:
            let args = call.arguments as! Dictionary<String,Any>
            let query = args["query"] as! String
            let countries = args["countries"] as? [String]? ?? [String]()
            let placeTypeFilters = args["typesFilter"] as? [String]
            let origin = latLngFromMap(argument: args["origin"] as? Dictionary<String, Any?>)
            let newSessionToken = args["newSessionToken"] as? Bool
            let locationBias = rectangularBoundsFromMap(argument: args["locationBias"] as? Dictionary<String, Any?>)
            let locationRestriction = rectangularBoundsFromMap(argument: args["locationRestriction"] as? Dictionary<String, Any?>)
            let sessionToken = getSessionToken(force: newSessionToken == true)

            // Create a type filter.
            let filter = GMSAutocompleteFilter()
            filter.types = placeTypeFilters;
            filter.countries = countries
            filter.origin = origin
            filter.locationBias = locationBias
            filter.locationRestriction = locationRestriction

            let request = GMSAutocompleteRequest(query: query)
            request.sessionToken = sessionToken
            request.filter = filter

            placesClient.fetchAutocompleteSuggestions(
                from: request,
                callback: { (results, error) in
                    if let error = error {
                        print("findAutoCompletePredictions error: \(error)")
                        result(FlutterError(
                            code: "API_ERROR",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    } else {
                        self.lastSessionToken = sessionToken
                        let mappedResult = self.suggestionsToList(results: results)
                        result(mappedResult)
                    }
                })
        case METHOD_FETCH_PLACE:
            let args = call.arguments as! Dictionary<String,Any>
            let placeId = args["placeId"] as! String
            let requestedFields = args["fields"] as? [String] ?? ALL_PLACE_FIELDS
            var properties: [GMSPlaceProperty] = []
            for field in requestedFields {
                properties.append(placePropertyFromStr(it: field))
            }
            let newSessionToken = args["newSessionToken"] as? Bool ?? false
            let sessionToken = getSessionToken(force: newSessionToken == true)

            let fetchPlaceRequest = GMSFetchPlaceRequest(
                placeID: placeId,
                placeProperties: properties.map { $0.rawValue },
                sessionToken: sessionToken
            )

            placesClient.fetchPlace(with: fetchPlaceRequest) { (place, error) in
                if let error = error {
                    print("fetchPlace error: \(error)")
                    result(FlutterError(
                        code: "API_ERROR",
                        message: error.localizedDescription,
                        details: nil
                    ))
                } else {
                    let mappedPlace = self.placeToMap(place: place)
                    result(mappedPlace)
                }
            }
        case METHOD_FETCH_PLACE_PHOTO:
            let args = call.arguments as! Dictionary<String,Any>
            let photoMetadataMap = args["photoMetadata"] as! Dictionary<String,Any>
            let photoRef = photoMetadataMap["photoReference"] as! String
            
            if let photoMetadata = photosCache[photoRef] {
                placesClient.loadPlacePhoto(photoMetadata, callback: { (photo, error) -> Void in
                    if let error = error {
                        print("fetchPlacePhoto error: \(error)")
                        result(FlutterError(
                            code: "API_ERROR_PHOTO",
                            message: error.localizedDescription,
                            details: nil
                        ))
                    } else {
                        let data = photo?.pngData()
                        result(data)
                    }
                })
            } else {
                result(FlutterError(
                    code: "API_ERROR_PHOTO",
                    message: "PhotoMetadata must be initially fetched with fetchPlace",
                    details: ""
                ))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func placeToMap(place: GMSPlace?) -> Dictionary<String, Any?> {
        guard let place = place else {
            return Dictionary<String, Any?>()
        }
        return [
            "address": place.formattedAddress,
            "addressComponents": place.addressComponents?.map { (it) in return addressComponentToMap(addressComponent: it) },
            "businessStatus": businessStatusToStr(it: place.businessStatus),
            "attributions": place.attributions,
            "latLng": latLngToMap(coordinate: place.coordinate),
            "name": place.name,
            "openingHours": openingHoursToMap(openingHours: place.openingHours),
            "phoneNumber": place.phoneNumber,
            "photoMetadatas": place.photos?.map { (it) in return photoMetadataToMap(photoMetadata: it) },
            "plusCode": plusCodeToMap(plusCode: place.plusCode),
            "priceLevel": place.priceLevel.rawValue,
            "rating": place.rating,
            "types": place.types?.map { (it) in return it.uppercased() },
            "userRatingsTotal": place.userRatingsTotal,
            "utcOffsetMinutes": place.utcOffsetMinutes,
            "viewport": latLngBoundsToMap(viewport: place.viewportInfo),
            "websiteUri": place.website?.absoluteString
        ]
    }
    
    private func businessStatusToStr(it: GMSPlacesBusinessStatus) -> String? {
        switch (it) {
        case GMSPlacesBusinessStatus.operational:
            return "OPERATIONAL";
        case GMSPlacesBusinessStatus.closedTemporarily:
            return "CLOSED_TEMPORARILY";
        case GMSPlacesBusinessStatus.closedPermanently:
            return "CLOSED_PERMANENTLY";
        default:
            return nil;
        }
    }
    
    private func plusCodeToMap(plusCode: GMSPlusCode?) -> Dictionary<String, Any?>? {
        guard let plusCode = plusCode else {
            return nil
        }
        
        return [
            "compoundCode": plusCode.compoundCode,
            "globalCode": plusCode.globalCode
        ]
    }
    
    private func photoMetadataToMap(photoMetadata: GMSPlacePhotoMetadata) -> Dictionary<String, Any?> {
        let photoRef = _getPhotoReference()
        
        photosCache[photoRef] = photoMetadata
        
        return [
            "photoReference": photoRef,
            "width": Int(photoMetadata.maxSize.width),
            "height": Int(photoMetadata.maxSize.height),
            "attributions": photoMetadata.attributions?.string
        ]
    }
    
    private func _getPhotoReference() -> String {
        let num = runningUid
        runningUid += 1
        return "id_" + String(num);
    }
    
    private func openingHoursToMap(openingHours: GMSOpeningHours?) -> Dictionary<String, Any?>? {
        guard let openingHours = openingHours else {
            return nil
        }
        return [
            "periods": openingHours.periods?.map { (it) in return periodToMap(period: it) },
            "weekdayText": openingHours.weekdayText
        ]
    }
    
    private func periodToMap(period: GMSPeriod) -> Dictionary<String, Any?> {
        return [
            "open": timeOfWeekToMap(event: period.openEvent),
            "close": timeOfWeekToMap(event: period.closeEvent)
        ]
    }
    
    private func timeOfWeekToMap(event: GMSEvent?) -> Dictionary<String, Any?>? {
        guard let event = event else {
            return nil
        }
        return [
            "day": dayOfWeekToStr(it: event.day),
            "time": placeLocalTimeToMap(time: event.time)
        ]
    }
    
    private func dayOfWeekToStr(it: GMSDayOfWeek) -> String {
        switch (it) {
        case GMSDayOfWeek.sunday: return "SUNDAY";
        case GMSDayOfWeek.monday: return "MONDAY";
        case GMSDayOfWeek.tuesday: return "TUESDAY";
        case GMSDayOfWeek.wednesday: return "WEDNESDAY";
        case GMSDayOfWeek.thursday: return "THURSDAY";
        case GMSDayOfWeek.friday: return "FRIDAY";
        case GMSDayOfWeek.saturday: return "SATURDAY";
        default: return "NULL";
        }
    }

    private func placeLocalTimeToMap(time: GMSTime) -> Dictionary<String, Any?> {
      return [
        "hours": time.hour,
        "minutes": time.minute
      ]
    }
    
    private func latLngToMap(coordinate: CLLocationCoordinate2D?) -> Any? {
        guard let coordinate = coordinate else {
            return nil
        }
        return [
            "lat": coordinate.latitude,
            "lng": coordinate.longitude
        ]
    }

    private func latLngBoundsToMap(viewport: GMSPlaceViewportInfo?) -> Dictionary<String, Any?>? {
        guard let viewport = viewport else {
            return nil
        }
        return [
            "southwest": latLngToMap(coordinate: viewport.southWest),
            "northeast": latLngToMap(coordinate: viewport.northEast)
        ]
    }

    private func addressComponentToMap(addressComponent: GMSAddressComponent) -> Dictionary<String, Any?> {
      return [
        "name": addressComponent.name,
        "shortName": addressComponent.shortName,
        "types": addressComponent.types
      ]
    }
    
    private func placePropertyFromStr(it: String) -> GMSPlaceProperty {
        switch (it) {
        case "ADDRESS": return GMSPlaceProperty.formattedAddress
        case "ADDRESS_COMPONENTS": return GMSPlaceProperty.addressComponents
        case "BUSINESS_STATUS": return GMSPlaceProperty.businessStatus
        case "ID": return GMSPlaceProperty.placeID
        case "LAT_LNG": return GMSPlaceProperty.coordinate
        case "NAME": return GMSPlaceProperty.name
        case "OPENING_HOURS": return GMSPlaceProperty.openingHours
        case "PHONE_NUMBER": return GMSPlaceProperty.phoneNumber
        case "PHOTO_METADATAS": return GMSPlaceProperty.photos
        case "PLUS_CODE": return GMSPlaceProperty.plusCode
        case "PRICE_LEVEL": return GMSPlaceProperty.priceLevel
        case "RATING": return GMSPlaceProperty.rating
        case "TYPES": return GMSPlaceProperty.types
        case "USER_RATINGS_TOTAL": return GMSPlaceProperty.userRatingsTotal
        case "UTC_OFFSET": return GMSPlaceProperty.utcOffsetMinutes
        case "VIEWPORT": return GMSPlaceProperty.viewport
        case "WEBSITE_URI": return GMSPlaceProperty.website
        default:
            fatalError("Invalid placeField: \(it)")
        }
    }

    private func suggestionsToList(results: [GMSAutocompleteSuggestion]?) -> [Dictionary<String, Any?>]? {
        guard let results = results else {
            return nil;
        }

        return results.compactMap { (suggestion: GMSAutocompleteSuggestion) in
            return suggestion.placeSuggestion.map { suggestionToMap(suggestion: $0) }
        }
    }

    private func suggestionToMap(suggestion: GMSAutocompletePlaceSuggestion) -> Dictionary<String, Any?> {
        // placeTypes is omitted: Places API (New) returns place types (e.g.
        // "non_profit_organization") that the Dart-side PlaceType enum,
        // generated against the legacy API's fixed type list, doesn't
        // recognize, and its fromJson throws on any unknown value. No caller
        // in this app reads placeTypes.
        return [
            "placeId": suggestion.placeID,
            "distanceMeters": suggestion.distanceMeters,
            "primaryText": suggestion.attributedPrimaryText.string,
            "secondaryText": suggestion.attributedSecondaryText?.string ?? "",
            "fullText": suggestion.attributedFullText.string,
        ];
    }

    private func getSessionToken(force: Bool) -> GMSAutocompleteSessionToken! {
        let localToken = lastSessionToken
        if (force || localToken == nil) {
            return GMSAutocompleteSessionToken.init()
        }
        return localToken
    }
    
    private func rectangularBoundsFromMap(argument: Dictionary<String, Any?>?) -> (GMSPlaceLocationBias & GMSPlaceLocationRestriction)? {
        guard let argument = argument,
              let southWest = latLngFromMap(argument: argument["southwest"] as? Dictionary<String, Any?>)?.coordinate as? CLLocationCoordinate2D,
              let northEast = latLngFromMap(argument: argument["northeast"] as? Dictionary<String, Any?>)?.coordinate as? CLLocationCoordinate2D
               else {
            return nil
        }
        
        return GMSPlaceRectangularLocationOption(northEast, southWest);
    }
    
    
    private func latLngFromMap(argument: Dictionary<String, Any?>?) -> CLLocation? {
        guard let argument = argument,
              let lat = argument["lat"] as? Double,
              let lng = argument["lng"] as? Double else {
            return nil
        }
        
        return CLLocation(latitude: lat, longitude: lng)
    }
    
    private func initialize(apiKey: String?) {
        GMSPlacesClient.provideAPIKey(apiKey ?? "")
        placesClient = GMSPlacesClient.shared()
    }
}
