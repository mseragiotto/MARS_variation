//
//  PositionProvider.swift
//  MARS
//
//  Created by Danil Lugli on 15/10/24.
//


import SwiftUI
import ARKit
import RoomPlan
import Foundation
import Accelerate
import CoreMotion

@available(iOS 16.0, *)
public class PositionProvider: PositionSubject, LocationObserver, @preconcurrency Hashable, ObservableObject, PositionObserver {

    // MARK: - Proprietà
    public var id: UUID = UUID()
    public let building: Building

    let delegate: ARSCNDelegate = ARSCNDelegate()
    let motionManager = CMMotionManager()
    
    var changeStateBool: Bool = false
    var markers: Set<ARReferenceImage>
    var firstPrint: Bool = false
    var positionObservers: [PositionObserver]
    
    var countNormal: Int = 0
    var countNormalCheckRoomFloor: Int = 0
    var readyToChange: Bool = false
    var lastKnownPosition: simd_float4x4 = simd_float4x4(1)
    var currentFloorPosition: simd_float4x4 = simd_float4x4(1)
    var firstLocalization: Bool = false
    var reLocalizingFrameCount = 0
    
    
    
    @Published var position: simd_float4x4 = simd_float4x4(0)
    @Published var trackingState: String = ""
    @Published var nodeContainedIn: String = ""
    @Published var roomMatrixActive: String = ""
    @Published var switchingRoom: Bool = false
    @Published var angleGradi: String = ""

    @Published var arSCNView: ARSCNViewContainer
    @Published var scnRoomView: SCNViewContainer = SCNViewContainer()
    @Published var scnFloorView: SCNViewContainer = SCNViewContainer()
    @Published var activeRoomPlanimetry: SCNViewContainer? = nil

    @Published var activeRoom: Room = Room()
    @Published var prevRoom: Room = Room()
    @Published var activeFloor: Floor = Floor()
    
    @Published var markerFounded: Bool = false
    @Published var showMarkerFoundedToast: Bool = false
    @Published var showChangeFloorToast: Bool = false

    let delegateMultiplexer: ARSCNDelegateMultiplexer = ARSCNDelegateMultiplexer()

    var showManagerCamera: Bool = false
    
    @Published var showOverlay: Bool = false
    var currentMatrix: simd_float4x4 = simd_float4x4(1.0)
    var offMatrix: simd_float4x4 = simd_float4x4(1.0)
    var cont: Int = 0
    
    // In PositionProvider.swift
    public var referenceMarkersByLocation: [String: Set<ARReferenceImage>] = [:]
    
    var positionOffTracking: simd_float4x4 = simd_float4x4(1)
    var floorNodePosition: SCNNode = SCNNode()
    var lastFloorPosition: simd_float4x4 = simd_float4x4(1)
    var lastFloorAngle: Float = 0.0

    private var worldMapConfigurationHandler: ((ARWorldTrackingConfiguration) -> Void)
    
    // MARK: - Inizializzazione


    public init(
        data: URL,
        arSCNView: ARSCNView,
        referenceMarkersByLocation: [String: Set<ARReferenceImage>] = [:],
        worldMapConfigurationHandler: ((ARWorldTrackingConfiguration) -> Void)? = nil
    ) {
        self.positionObservers = []
        self.markers = []
        self.referenceMarkersByLocation = referenceMarkersByLocation
        self.delegateMultiplexer.addDelegate(self.delegate)
        
        self.arSCNView = ARSCNViewContainer(arSCNView: arSCNView, delegate: delegateMultiplexer)
        self.scnFloorView = SCNViewContainer()
        self.scnRoomView = SCNViewContainer()
        
        // Imposta la closure passata dall'utente o usa quella di default
        self.worldMapConfigurationHandler = worldMapConfigurationHandler ?? { config in
            config.planeDetection = [.horizontal, .vertical]
            config.environmentTexturing = .automatic
            config.isCollaborationEnabled = true
        }

        do {
            self.building = try FileHandler.loadBuildings(from: data)
        } catch {
            self.building = Building()
        }
        
        self.delegate.positionProvider = self
        self.delegate.addLocationObserver(positionObserver: self)
    }
    
    // MARK: - Gestione della Sessione AR

    /// Configura la sessione AR per il tracciamento delle immagini
    public func start() {
        self.arSCNView.getSessionManager().activate()
        if building.detectionImages.isEmpty {
        } else {
            print("DEBUG: \(building.detectionImages.count) immagini caricate nel building.")
        }
        self.arSCNView.getSessionManager().addImageTrackingToConfiguration(with: self.building.detectionImages)
    }
    
    
    // MARK: - Aggiornamento della Posizione e Tracking
    @MainActor
    public func onLocationUpdate(_ newPosition: simd_float4x4, _ newTrackingState: String) {
        switch switchingRoom {
        case false:
            if showManagerCamera {
                self.arSCNView.getSessionManager().coachingOverlay.setActive(false, animated: true)
                self.showOverlay = true
                showManagerCamera = false
            }
            
            self.position = newPosition
            self.trackingState = newTrackingState
            self.roomMatrixActive = self.activeRoom.name
            
            reLocalizingFrameCount = 0
            updateTrackingState(newState: newTrackingState)
            
            scnRoomView.updatePosition(self.position, nil, floor: self.activeFloor)
            
            if !changeStateBool {
                print("AGGIORNO FLOOR POS")
                self.currentFloorPosition = self.scnFloorView.updatePosition(
                    self.position,
                    self.activeFloor.associationMatrix[self.activeRoom.name],
                    floor: self.activeFloor
                )
                
                self.updateCameraPosition(currentFloorPosition)
            }
            
            countNormal += 1
            if countNormal == 5 {
                changeStateBool = false
            }
            
            if let posFloorNode = scnFloorView.scnView.scene?.rootNode.childNodes.first(where: { $0.name == "POS_FLOOR" }) {
                self.lastFloorPosition = posFloorNode.simdWorldTransform
                self.lastFloorAngle = getRotationAngles(from: posFloorNode.simdWorldTransform).yaw
                self.offMatrix = updateMatrixWithYawTest(matrix: self.lastFloorPosition, yawRadians: self.lastFloorAngle)
            } else {
                self.lastFloorPosition = simd_float4x4(1)
            }
            
            readyToChange = false
            countNormalCheckRoomFloor += 1
            
            if countNormalCheckRoomFloor >= 20 {
                checkSwitchRoom(state: true)
                checkSwitchFloor()
                countNormalCheckRoomFloor = 0
            }
            
        case true:
            countNormal = 0
            lastKnownPosition = position
            position = newPosition
            trackingState = newTrackingState

            positionOffTracking = calculatePositionOffTracking(lastFloorPosition: lastFloorPosition, newPosition: newPosition)
            scnRoomView.updatePosition(newPosition, nil, floor: activeFloor)

            if trackingState == "Re-Localizing..." {
                reLocalizingFrameCount += 1
                
                if reLocalizingFrameCount >= 120 {
                    showManagerCamera = true
                    self.arSCNView.getSessionManager().coachingOverlay.setActive(true, animated: true)
                    self.showOverlay = true
                }
                
                self.scnFloorView.updatePosition(self.positionOffTracking, nil, floor: self.activeFloor)
                self.updateCameraPosition(self.positionOffTracking)
                self.currentFloorPosition = self.positionOffTracking
                
                readyToChange = true
            } else {
                reLocalizingFrameCount = 0
            }

            if readyToChange && newTrackingState != "Normal" {
                switchingRoom = true
                changeStateBool = false
            } else {
                switchingRoom = false
            }
        }
    }
    
    // MARK: - Riconoscimento e Cambio Room/Floor

    /// Cerca la room corrispondente a un marker e la gestisce
    func findRoomFromMarker(markerName: String) {
        for floor in self.building.floors {
            for room in floor.rooms {
                if room.referenceMarkers.contains(where: { $0.name == markerName }) {
                    self.roomRecognized(room)
                    return
                }
            }
        }
    }
    
    /// Metodo aggiornato per usare la closure di configurazione
    func updateWorldMapConfiguration() {
        let currentRoom = self.activeRoom.name
        let specificMarkers = self.referenceMarkersByLocation[currentRoom] ?? Set<ARReferenceImage>()
        
        self.arSCNView.getSessionManager().addWorldMapToConfiguration(
            with: self.activeRoom,
            detectionImages: specificMarkers,
            configure: self.worldMapConfigurationHandler
        )
    }
    
    /// Imposta la room riconosciuta e aggiorna le viste corrispondenti
    func roomRecognized(_ room: Room) {
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.activeFloor = room.parentFloor ?? self.building.floors.first ?? Floor()
            self.activeRoom = room
            self.roomMatrixActive = room.name
            self.activeRoomPlanimetry = room.planimetry
            self.prevRoom = room

            let roomNodes = self.activeFloor.rooms.map { $0.name }
                        
            self.scnFloorView.loadPlanimetry(scene: self.activeFloor, roomsNode: roomNodes, borders: true, nameCaller: self.activeFloor.name)
            self.scnRoomView.loadPlanimetry(scene: self.activeRoom, roomsNode: nil, borders: true, nameCaller: self.activeRoom.name)
            
            self.updateWorldMapConfiguration()
            addRoomNodesToScene(floor: self.activeFloor, scene: self.scnFloorView.scnView.scene!)
            
            // Aggiorna i marker e la configurazione
            let currentRoom = self.activeRoom.name
            let specificMarkers = self.referenceMarkersByLocation[currentRoom] ?? Set<ARReferenceImage>()
            
            
            self.arSCNView.getSessionManager().addWorldMapToConfiguration(
                        with: self.activeRoom,
                        detectionImages: specificMarkers,
                        configure: self.worldMapConfigurationHandler
                    )
            
            self.markerFounded = true
            firstLocalization = true
            self.showMarkerFoundedToast = true
        }
    }
    
    /// Controlla se il nodo di posizione appartiene ad una nuova room
    func checkSwitchRoom(state: Bool) {
        print("CHECK SWITCH ROOM")
        guard let posFloorNode = scnFloorView.scnView.scene?.rootNode.childNode(withName: "POS_FLOOR", recursively: true) else {
            return
        }
        
        let roomsNode = getNodesMatchingRoomNames(from: activeFloor, in: scnFloorView.scnView)
        for room in roomsNode {
            print(room.name)
        }
        
        let nextRoomName = findPositionContainer(for: posFloorNode.worldPosition)?.name ?? "Error Contained"
        self.nodeContainedIn = nextRoomName
        
        if nextRoomName != activeRoom.name, activeFloor.rooms.contains(where: { $0.name == nextRoomName }) {
            if nextRoomName == "Error Contained" { return }
            self.switchingRoom = true
            
            if state {
                prevRoom = activeRoom
                self.roomMatrixActive = prevRoom.name
            }
            
            self.activeRoom = activeFloor.getRoom(byName: nextRoomName) ?? prevRoom

            // Aggiorna i marker e la configurazione
            let currentRoom = self.activeRoom.name
            let specificMarkers = self.referenceMarkersByLocation[currentRoom] ?? Set<ARReferenceImage>()
            
            // Usare il session manager per aggiornare la world map
            self.arSCNView.getSessionManager().addWorldMapToConfiguration(
                with: activeRoom,
                detectionImages: specificMarkers,
                configure: self.worldMapConfigurationHandler
            )
            
            
            
            let roomNames = activeFloor.rooms.map { $0.name }
            scnRoomView.loadPlanimetry(scene: activeRoom, roomsNode: roomNames, borders: true, nameCaller: activeRoom.name)
        } else {
            print("No change Room: \(self.nodeContainedIn)")
        }
    }

    /// Controlla se la posizione attuale richiede un cambio di piano
    func checkSwitchFloor() {
        guard let posRoomNode = scnRoomView.scnView.scene?.rootNode.childNodes.first(where: { $0.name == "POS_ROOM" }) else {
            return
        }
        
        print("CHECK SWITCH FLOOR")
        for connection in self.activeRoom.connections {
            print("Y ROOM: \(posRoomNode.simdWorldTransform.columns.3.y)\n")
            print("Altitude connection: \(connection.altitude)\n")
            
            if posRoomNode.simdWorldTransform.columns.3.y >= connection.altitude - 0.5 &&
                posRoomNode.simdWorldTransform.columns.3.y <= connection.altitude + 0.5 {
                let nextFloorName = connection.targetFloor
                print("Next Floor Name: \(nextFloorName)")
                let nextRoomName = connection.targetRoom
                print("Next Room Name: \(nextRoomName)")
                
                if nextFloorName != activeFloor.name,
                   let nextFloor = Floor.getFloorByName(from: building.floors, name: nextFloorName),
                   let nextRoom = nextFloor.getRoom(byName: nextRoomName) {
                    
                    prevRoom = activeRoom
                    print("DEBUG OK -> Next Floor: \(nextFloor.name)")
                    print("DEBUG OK -> Next Room: \(nextRoom.name)")
                    self.activeFloor = nextFloor
                    self.activeRoom = nextRoom
                    
                    let roomNames = activeFloor.rooms.map { $0.name }
                    
                    scnRoomView.loadPlanimetry(scene: activeRoom, roomsNode: roomNames, borders: true, nameCaller: activeRoom.name)
                    scnFloorView.loadPlanimetry(scene: activeFloor, roomsNode: roomNames, borders: true, nameCaller: activeRoom.name)
                    addRoomNodesToScene(floor: self.activeFloor, scene: self.scnFloorView.scnView.scene!)

                    // Aggiorna i marker e la configurazione
                    let currentRoom = self.activeRoom.name
                    let specificMarkers = self.referenceMarkersByLocation[currentRoom] ?? Set<ARReferenceImage>()
                    
                    // Usare il session manager per aggiornare la world map
                    self.arSCNView.getSessionManager().addWorldMapToConfiguration(
                        with: activeRoom,
                        detectionImages: specificMarkers,
                        configure: self.worldMapConfigurationHandler
                    )
                    
                    
                    // Usare il session manager per aggiornare la world map
                    self.arSCNView.getSessionManager().addWorldMapToConfiguration(with: activeRoom)
                    showChangeFloorToast = true

                    // Mostrare l'overlay della coaching per la guida utente
                    self.arSCNView.getSessionManager().coachingOverlay.setActive(true, animated: true)
                    self.showOverlay = true
                }
            }
        }
    }

    /// Aggiorna lo stato del tracking per gestire le transizioni tra le modalità
    func updateTrackingState(newState: String) {
        if previousTrackingState == "Re-Localizing..." && newState == "Normal" {
            firstLocalization = false
            self.arSCNView.getSessionManager().coachingOverlay.setActive(false, animated: true)
            self.showOverlay = false
        }
        
        // Aggiorna lo stato precedente per il prossimo confronto
        previousTrackingState = newState
    }
    
    private var previousTrackingState: String = ""
    // MARK: - Operazioni su Matrici e Trasformazioni

    /// Restituisce true se la distanza in piano XZ tra due trasformazioni è >= 1 metro
    func checkDifferentMovement(from lastPosition: simd_float4x4,
                                   to actualPosition: simd_float4x4) -> Bool {
        let posA = simd_make_float3(lastPosition.columns.3)
        let posB = simd_make_float3(actualPosition.columns.3)
        let dx = posB.x - posA.x
        let dz = posB.z - posA.z
        let distanceXZ = sqrtf(dx * dx + dz * dz)
        return distanceXZ >= 1.0
    }
    
    /// Calcola la posizione off-tracking usando la matrice “offMatrix”
    func calculatePositionOffTracking(lastFloorPosition: simd_float4x4, newPosition: simd_float4x4) -> simd_float4x4 {
        positionOffTracking = offMatrix * newPosition
        return positionOffTracking
    }
    
    /// Aggiorna la matrice sostituendo le prime tre colonne con quelle di una rotazione attorno all’asse Y
    func updateMatrixWithYawTest(matrix: simd_float4x4, yawRadians: Float) -> simd_float4x4 {
        let rotationY = simd_float3x3(
            simd_make_float3(cos(yawRadians), 0, -sin(yawRadians)), // asse X
            simd_make_float3(0, 1, 0),                               // asse Y
            simd_make_float3(sin(yawRadians), 0, cos(yawRadians))     // asse Z
        )
        var combinedMatrix = matrix // Copia la matrice originale
        combinedMatrix.columns.0 = simd_make_float4(rotationY.columns.0, 0)
        combinedMatrix.columns.1 = simd_make_float4(rotationY.columns.1, 0)
        combinedMatrix.columns.2 = simd_make_float4(rotationY.columns.2, 0)
        combinedMatrix.columns.3 = matrix.columns.3
        return combinedMatrix
    }
    
    /// Crea una matrice che combina una traslazione e una rotazione attorno all’asse Y
    func createRotoTranslationMatrix(translation: simd_float3, angleY: Float) -> simd_float4x4 {
        let cosAngle = cos(angleY)
        let sinAngle = sin(angleY)
        let rotationMatrix = simd_float4x4(
            simd_float4(cosAngle, 0, sinAngle, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(-sinAngle, 0, cosAngle, 0),
            simd_float4(0, 0, 0, 1)
        )
        var translationMatrix = simd_float4x4(1)
        translationMatrix.columns.3 = simd_float4(translation.x, translation.y, translation.z, 1)
        return translationMatrix * rotationMatrix
    }
    
    /// Estrae gli angoli di rotazione (roll, pitch, yaw) da una matrice 4x4
    func getRotationAngles(from matrix: simd_float4x4) -> (roll: Float, pitch: Float, yaw: Float) {
        let pitch = atan2(-matrix[2][1], sqrt(matrix[0][1] * matrix[0][1] + matrix[1][1] * matrix[1][1]))
        let yaw = atan2(matrix[2][0], matrix[2][2])
        let roll = atan2(matrix[0][1], matrix[1][1])
        return (roll, pitch, yaw)
    }
    
    /// Crea una matrice di rotazione attorno all’asse Y dato un angolo
    func createRotationMatrixY(angle: Float) -> simd_float4x4 {
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        return simd_float4x4(
            simd_float4(cosAngle, 0, sinAngle, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(-sinAngle, 0, cosAngle, 0),
            simd_float4(0, 0, 0, 1)
        )
    }
    
    // MARK: - Gestione dei Nodi nella Scena

    /// Restituisce i nodi la cui proprietà name corrisponde a una delle room del floor
    @available(iOS 16.0, *)
    func getNodesMatchingRoomNames(from floor: Floor, in scnFloorView: SCNView) -> [SCNNode] {
        let roomNames = Set(floor.rooms.map { $0.name })
        guard let rootNode = scnFloorView.scene?.rootNode else {
            print("La scena non ha un rootNode.")
            return []
        }
        let matchingNodes = rootNode.childNodes.filter { node in
            if let nodeName = node.name {
                return roomNames.contains(nodeName)
            }
            return false
        }
        return matchingNodes
    }
    
    /// Cerca, a partire da una posizione, il container (nodo) relativo a una room
    func findPositionContainer(for positionVector: SCNVector3) -> SCNNode? {
        let roomNames = Set(activeFloor.rooms.map { $0.name })
        for roomNode in scnFloorView.scnView.scene!.rootNode.childNodes {
            guard let floorNodeName = roomNode.name,
                  floorNodeName.starts(with: "Floor_"),
                  let roomName = floorNodeName.split(separator: "_").last,
                  roomNames.contains(String(roomName))
            else { continue }
            
            if let matchingChildNode = roomNode.childNode(withName: String(roomName), recursively: true) {
                let localPosition = matchingChildNode.convertPosition(positionVector, from: nil)
                if isPositionContained(localPosition, in: matchingChildNode) {
                    return matchingChildNode
                }
            } else {
                print("No matching child node found for room: \(roomName)")
            }
        }
        return nil
    }
    
    /// Verifica se una posizione (locale) è contenuta all'interno del nodo (usando un hit-test)
    private func isPositionContained(_ position: SCNVector3, in node: SCNNode) -> Bool {
        guard node.geometry != nil else { return false }
        let hitTestOptions: [String: Any] = [
            SCNHitTestOption.backFaceCulling.rawValue: false,
            SCNHitTestOption.boundingBoxOnly.rawValue: false,
            SCNHitTestOption.ignoreHiddenNodes.rawValue: false
        ]
        let rayOrigin = position
        let rayDirection = SCNVector3(0, 0, 1)
        let rayEnd = PositionProvider.sum(lhs: rayOrigin, rhs: rayDirection)
        let hitResults = node.hitTestWithSegment(from: rayOrigin, to: rayEnd, options: hitTestOptions)
        
        if let closestHit = hitResults.min(by: { $0.worldCoordinates.z < $1.worldCoordinates.z }) {
            print("Nodo più vicino trovato: \(closestHit.node.name ?? "Sconosciuto") a \(closestHit.worldCoordinates)")
            return true
        }
        return false
    }
    
    /// Aggiunge un marker di debug (una sfera colorata) nella scena
    func addDebugMarker(at position: SCNVector3, color: UIColor, scene: SCNScene) {
        let sphere = SCNSphere(radius: 0.05)
        sphere.firstMaterial?.diffuse.contents = color
        let markerNode = SCNNode(geometry: sphere)
        markerNode.position = position
        scene.rootNode.addChildNode(markerNode)
    }
    
    // MARK: - Pattern Osservatore

    /// Mostra la mappa (vista SwiftUI) basata sulla posizione
    @MainActor
    public func showMap() -> some View {
        return MapView(locationProvider: self)
    }
    
    func addLocationObserver(positionObserver: PositionObserver) {
        if !self.positionObservers.contains(where: { $0.id == positionObserver.id }) {
            self.positionObservers.append(positionObserver)
        }
    }
    
    func removeLocationObserver(positionObserver: PositionObserver) {
        self.positionObservers = self.positionObservers.filter { $0.id != positionObserver.id }
    }
    
    static private func sum(lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        return SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }
    
    public func onRoomChanged(_ newRoom: Room) {
        // TODO: Gestire il cambio di room
    }
    
    public func onFloorChanged(_ newFloor: Floor) {
        // TODO: Gestire il cambio di floor
    }
    
    public func notifyRoomChanged(newRoom: Room) {
        for positionObserver in self.positionObservers {
            positionObserver.onRoomChanged(newRoom)
        }
    }
    
    public func notifyFloorChanged(newFloor: Floor) {
        for positionObserver in self.positionObservers {
            positionObserver.onFloorChanged(newFloor)
        }
    }
    

    func notifyLocationUpdate(newLocation: simd_float4x4, newTrackingState: String) {
        for positionObserver in self.positionObservers {
            positionObserver.onLocationUpdate(newLocation, newTrackingState)
        }
    }
    
    @MainActor
    func updateCameraPosition(_ newPosition: simd_float4x4) {
        let cameraNode = self.scnFloorView.cameraNode

        cameraNode.position = SCNVector3(
            newPosition.columns.3.x,
            newPosition.columns.3.y + 10,
            newPosition.columns.3.z
        )
        
        cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)

        self.scnFloorView.scnView.pointOfView?.position = SCNVector3(newPosition.columns.3.x, 15.0 + newPosition.columns.3.y, newPosition.columns.3.z)
        
    }
    
    // MARK: - Metodi di Debug

    public func printMatrix() {
        if cont == 0 {
            print("\nInitial Matrix (lastFloorPosition)")
            printSimdFloat4x4(self.lastFloorPosition)
            print("\n")
            let rotationAngles = getRotationAngles(from: self.lastFloorPosition)
            print("Roll: \(rotationAngles.roll.radiansToDegrees)°")
            print("Pitch: \(rotationAngles.pitch.radiansToDegrees)°")
            print("Yaw: \(rotationAngles.yaw.radiansToDegrees)°")
            print("\n")
            
            print("Last Matrix (self.position)")
            printSimdFloat4x4(self.position)
            print("\n")
            let rotationAngles2 = getRotationAngles(from: self.position)
            print("Roll: \(rotationAngles2.roll.radiansToDegrees)°")
            print("Pitch: \(rotationAngles2.pitch.radiansToDegrees)°")
            print("Yaw: \(rotationAngles2.yaw.radiansToDegrees)°")
            print("\n")
            print("_____________________________________\n")
        }
        
        print("_____________________________________\n")
        print("\nMatrix (self.position) n°: \(cont)")
        printSimdFloat4x4(self.position)
        print("\n")
        let rotationAngles = getRotationAngles(from: self.position)
        print("Roll: \(rotationAngles.roll.radiansToDegrees)°")
        print("Pitch: \(rotationAngles.pitch.radiansToDegrees)°")
        print("Yaw: \(rotationAngles.yaw.radiansToDegrees)°")
        print("\n")
        print("Matrix (positionOffTracking) n°: \(cont)")
        printSimdFloat4x4(positionOffTracking)
        print("\n")
        let rotationAngles2 = getRotationAngles(from: self.positionOffTracking)
        print("Roll: \(rotationAngles2.roll.radiansToDegrees)°")
        print("Pitch: \(rotationAngles2.pitch.radiansToDegrees)°")
        print("Yaw: \(rotationAngles2.yaw.radiansToDegrees)°")
        print("\n")
        
        cont += 1
    }
    
    public func printMatrix2() {
        print("_____________________________________\n")
        print("\nMatrix (offMatrix) n°: \(cont)")
        printSimdFloat4x4(offMatrix)
        print("\n")
        let rotationAngles = getRotationAngles(from: offMatrix)
        print("Roll: \(rotationAngles.roll.radiansToDegrees)°")
        print("Pitch: \(rotationAngles.pitch.radiansToDegrees)°")
        print("Yaw: \(rotationAngles.yaw.radiansToDegrees)°")
        print("\n")
        print("Matrix (newPosition) n°: \(cont)")
        printSimdFloat4x4(self.position)
        print("\n")
        let rotationAngles2 = getRotationAngles(from: self.position)
        print("Roll: \(rotationAngles2.roll.radiansToDegrees)°")
        print("Pitch: \(rotationAngles2.pitch.radiansToDegrees)°")
        print("Yaw: \(rotationAngles2.yaw.radiansToDegrees)°")
        print("\n")
        
        cont += 1
    }
    
    // MARK: - Equatable & Hashable

    public static func == (lhs: PositionProvider, rhs: PositionProvider) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct LocationKey: Hashable {
    let first: String
    let second: String
}
