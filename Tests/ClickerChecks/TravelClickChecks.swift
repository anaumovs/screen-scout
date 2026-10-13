import Foundation
import CoreGraphics
import ScoutClicker

private struct TravelRecord {
    let kind: String
    let point: CGPoint
    let time: Double
    let phase: String?
}
@MainActor private final class TravelRig {
    let mouse = FakeMouse(), clock = Clock()
    var engine: ClickEngine!
    var settings = ClickSettings()
    var records: [TravelRecord] = []
    var phases: [(String, Double)] = []
    var cycleDraws = 0, breakDraws = 0, intervalDraws = 0
    init(small: Bool = false, large: Bool = true, smallClicks: Bool = false, largeClicks: Bool = true, speed: Double = 1) {
        settings.smallMovementEnabled=small;settings.largeMovementEnabled=large
        settings.smallClickWhileMoving=smallClicks;settings.largeClickWhileMoving=largeClicks;settings.largeMovementSpeed=speed
        settings.movementProbability=1;settings.largeMovementProbability=1;settings.movementRadius=50
        settings.minInterval=0.12;settings.maxInterval=0.12;settings.randomIntervalsEnabled=false;settings.breaksEnabled=false
        engine=ClickEngine(output:mouse,scheduler:clock,random:{ [weak self] r in
            if r == 0...1 { self?.cycleDraws += 1 }
            return (r.lowerBound+r.upperBound)/2
        })
        mouse.observe={ [weak self] kind,point in
            guard let self else { return }
            self.records.append(TravelRecord(kind:kind,point:point,time:self.clock.now,phase:self.engine.movementPhase))
        }
        engine.changed={ [weak self] in
            guard let self,let phase=self.engine.movementPhase else { return }
            if self.phases.last?.0 != phase { self.phases.append((phase,self.clock.now)) }
        }
    }
    func start() { engine.start(at:mouse.position,settings:settings) }
    var downs: [TravelRecord] { records.filter { $0.kind.hasPrefix("down") } }
    func untilFirstArrival() {
        for _ in 0..<1500 {
            clock.advance(0.01)
            if !phases.isEmpty && engine.movementPhase == nil && mouse.held == nil { return }
        }
    }
    func pairedWithoutDragging() -> Bool {
        var held:TravelRecord?
        for r in records {
            if r.kind == "move" && held != nil { return false }
            if r.kind.hasPrefix("down") { if held != nil { return false };held=r }
            if r.kind.hasPrefix("up") || r.kind.hasPrefix("release") {
                guard let down=held, down.point == r.point, down.kind.dropFirst(5) == r.kind.dropFirst(r.kind.hasPrefix("up") ? 3 : 8) else { return false }
                held=nil
            }
        }
        return held == nil
    }
}
@MainActor func travelClickChecks(_ test: (String, () -> Bool) -> Void) {
    test("New preferences migrate to 1x speed and both travel switches off without changing old values") {
        var old=ClickSettings();old.largeMovementEnabled=true;old.movementRadius=37;old.minInterval=0.4;old.maxInterval=0.9
        old.timerEnabled=true;old.timerMinutes=31;old.timerSeconds=26;old.finalClickEnabled=true;old.finalButton = .left
        var json=try! JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
        for key in ["largeMovementSpeed","smallClickWhileMoving","largeClickWhileMoving"] { json.removeValue(forKey:key) }
        let migrated=try! JSONDecoder().decode(ClickSettings.self,from:JSONSerialization.data(withJSONObject:json))
        return migrated == old && migrated.largeMovementSpeed == 1 && !migrated.smallClickWhileMoving && !migrated.largeClickWhileMoving
    }
    test("Independent travel switches and speed persist while both movements are disabled") {
        var s=ClickSettings();s.smallMovementEnabled=false;s.largeMovementEnabled=false;s.smallClickWhileMoving=false;s.largeClickWhileMoving=true;s.largeMovementSpeed=9.5
        return (try! JSONDecoder().decode(ClickSettings.self,from:JSONEncoder().encode(s))) == s
    }
    test("Speed validation rejects nonfinite and values outside 1x to 10x") {
        for speed in [0.0,0.9,10.1,Double.infinity,Double.nan] { var s=ClickSettings();s.largeMovementSpeed=speed;if s.validationError == nil { return false } };return true
    }
    for smallClick in [false,true] { for largeClick in [false,true] {
        test("Both paths obey independent travel switches small=\(smallClick), large=\(largeClick)") {
            let r=TravelRig(small:true,large:true,smallClicks:smallClick,largeClicks:largeClick)
            r.start();r.untilFirstArrival();r.engine.stop()
            let small=r.downs.filter {$0.phase?.hasPrefix("Small") == true},large=r.downs.filter {$0.phase?.hasPrefix("Large") == true}
            return small.isEmpty != smallClick && large.isEmpty != largeClick &&
                (!smallClick || Set(small.compactMap(\.phase)) == ["Small outward","Small return"]) &&
                (!largeClick || Set(large.compactMap(\.phase)) == ["Large outward","Large return"]) && r.pairedWithoutDragging()
        }
    } }
    test("Main regular-clicking off suppresses both travel switches at every speed") {
        for speed in [1.0,10.0] {
            let r=TravelRig(small:true,large:true,smallClicks:true,largeClicks:true,speed:speed);r.settings.regularClickingEnabled=false
            r.start();r.clock.advance(8);r.engine.stop()
            if !r.downs.isEmpty || r.records.filter({$0.kind == "move"}).count<20 { return false }
        };return true
    }
    test("Same curved samples at 1x and 10x; outward and return animation timing scales exactly") {
        var traces:[[CGPoint]]=[],durations:[Double]=[]
        for speed in [1.0,10.0] {
            let r=TravelRig(largeClicks:false,speed:speed);r.settings.minInterval=100;r.settings.maxInterval=100
            r.start();r.untilFirstArrival()
            let moves=r.records.filter {$0.kind == "move" && $0.phase != nil}
            traces.append(moves.map(\.point));durations.append(moves.last!.time-moves.first!.time)
        }
        return traces[0] == traces[1] && abs(durations[0]/durations[1]-10)<0.00001
    }
    test("Large speed does not alter small-movement samples or timings") {
        var results:[[TravelRecord]]=[]
        for speed in [1.0,10.0] {
            let r=TravelRig(small:true,large:false,smallClicks:false,largeClicks:false,speed:speed);r.settings.minInterval=100;r.settings.maxInterval=100
            r.start();r.untilFirstArrival();results.append(r.records)
        }
        return results[0].count==results[1].count && zip(results[0],results[1]).allSatisfy { $0.point==$1.point && abs($0.time-$1.time)<0.00001 }
    }
    test("Speed changes travel duration without changing fixed click deadlines") {
        for speed in [1.0,5.0,10.0] {
            let r=TravelRig(speed:speed);r.start();r.untilFirstArrival();r.clock.advance(0.1);r.engine.stop()
            guard r.downs.count>=3 else { return false }
            for (a,b) in zip(r.downs,r.downs.dropFirst()) { if abs((b.time-a.time)-0.12)>0.00001 { return false } }
            if !r.pairedWithoutDragging() { return false }
        };return true
    }
    test("Return completion and turnaround do not create bonus clicks or reset cadence") {
        let r=TravelRig(small:true,large:true,smallClicks:true,largeClicks:true);r.start();r.untilFirstArrival();r.clock.advance(0.12);r.engine.stop()
        let gaps=zip(r.downs,r.downs.dropFirst()).map { $1.time-$0.time }
        return !gaps.isEmpty && gaps.allSatisfy { abs($0-0.12)<0.00001 } && r.downs.contains {$0.phase == nil}
    }
    test("Suppressed phases have no queued burst after returning") {
        let r=TravelRig(small:true,large:true,smallClicks:true,largeClicks:false);r.start();r.untilFirstArrival();r.clock.advance(0.13);r.engine.stop()
        return !r.downs.contains {$0.phase?.hasPrefix("Large") == true} && zip(r.downs,r.downs.dropFirst()).allSatisfy {$1.time-$0.time>=0.119999} && r.pairedWithoutDragging()
    }
    test("Travel clicks neither resample movement decisions nor sample breaks") {
        let r=TravelRig();r.settings.breaksEnabled=true;r.settings.breakProbability=1;r.settings.minBreak=10;r.settings.maxBreak=10
        r.start();r.clock.advance(0.13);let planningDraws=r.cycleDraws;r.clock.advance(0.87)
        return r.downs.count>5 && r.cycleDraws == planningDraws && r.engine.status != .takingBreak && r.phases.map(\.0).filter({$0 == "Large outward"}).count == 1
    }
    test("Random click timing is drawn once per click, within interval limits, independent of animation") {
        let m=FakeMouse(),c=Clock();var s=ClickSettings();s.smallMovementEnabled=false;s.largeMovementEnabled=true;s.largeMovementProbability=1;s.largeClickWhileMoving=true;s.breaksEnabled=false;s.minInterval=0.1;s.maxInterval=0.2
        var draws=0,times=[Double]()
        m.observe={kind,_ in if kind.hasPrefix("down") { times.append(c.now) } }
        let e=ClickEngine(output:m,scheduler:c,random:{range in
            if range == 0.1...0.2 { draws += 1;return draws%2 == 0 ? 0.1 : 0.2 };return (range.lowerBound+range.upperBound)/2
        })
        e.start(at:m.position,settings:s);c.advance(1.2);e.stop()
        let gaps=zip(times,times.dropFirst()).map {$1-$0}
        return draws == times.count && gaps.contains {abs($0-0.1)<0.00001} && gaps.contains {abs($0-0.2)<0.00001} && gaps.allSatisfy {$0>=0.09999 && $0<=0.20001}
    }
    test("Variation is sampled once; travel clicks leave the saved and return coordinates unchanged") {
        let r=TravelRig();r.settings.clickVariationEnabled=true;r.settings.clickVariationRadius=2
        let anchor=r.mouse.position;r.start();r.untilFirstArrival();r.engine.stop()
        let returns=r.records.filter {$0.kind == "move" && $0.phase == "Large return"}
        guard let end=returns.last else { return false }
        let expected=CGPoint(x:anchor.x-sqrt(0.5)*2,y:anchor.y)
        return r.engine.target == anchor && movementDistance(end.point,expected)<0.00001 && r.downs.contains {movementDistance($0.point,anchor)>10}
    }
    test("Maximum-speed large travel clicks and each segment respect a thin blocked obstacle") {
        let r=TravelRig(speed:10);let bounds=CGRect(x:0,y:0,width:800,height:600),blocked=CGRect(x:299.9,y:100,width:0.2,height:250)
        let domain=MovementDomain(bounds:bounds,blocked:[blocked])
        r.settings.movementRegions=[MovementRegionProfile(displayIdentity:"test-display",referenceSize:bounds.size,boxes:[MovementBox(rect:blocked,blocked:true)])]
        let anchor=r.mouse.position;r.start();r.untilFirstArrival();r.engine.stop();var last=anchor
        for record in r.records where record.phase?.hasPrefix("Large") == true {
            if !domain.contains(record.point) || !domain.permitsSegment(last,record.point) { return false };last=record.point
        }
        return r.downs.filter {$0.phase?.hasPrefix("Large") == true}.count>=2 && r.pairedWithoutDragging()
    }
    test("Manual pointer movement into a blocked box cannot receive a travel click or change target") {
        let r=TravelRig();let blocked=CGRect(x:650,y:400,width:50,height:50)
        r.settings.movementRegions=[MovementRegionProfile(displayIdentity:"test-display",referenceSize:CGSize(width:800,height:600),boxes:[MovementBox(rect:blocked,blocked:true)])]
        let anchor=r.mouse.position;r.start();r.clock.advance(0.13);r.mouse.position=CGPoint(x:675,y:425);r.clock.advance(0.03)
        return r.engine.active && r.engine.target == anchor && !r.downs.contains {blocked.contains($0.point)} && r.engine.movementNote?.contains("boundary") == true
    }
    test("Manual displacement within an allowed region rejoins path before travel clicking") {
        let r=TravelRig();r.start();r.clock.advance(0.13);let manual=CGPoint(x:650,y:500);r.mouse.position=manual;r.clock.advance(0.2)
        return r.engine.active && !r.downs.isEmpty && r.downs.allSatisfy { $0.point != manual } && r.engine.target==CGPoint(x:200,y:200)
    }
    test("Pause, Stop and permission loss during travel hold release immediately and cancel all callbacks") {
        for action in 0..<3 {
            let r=TravelRig();r.start();r.clock.advance(0.14);guard r.mouse.held != nil else { return false }
            if action==0 {r.engine.pause()} else if action==1 {r.engine.stop()} else {r.mouse.available=false;r.engine.checkEnvironment()}
            let count=r.records.count;r.clock.advance(100,forceCancelled:true)
            if r.engine.active || r.mouse.held != nil || r.records.count != count || !r.pairedWithoutDragging() { return false }
        };return true
    }
    test("Timer expiry during travel hold releases it before one exact final click, unaffected by speed") {
        for speed in [1.0,10.0] {
            let r=TravelRig(speed:speed);r.settings.minInterval=0.85;r.settings.maxInterval=0.85
            r.settings.timerEnabled=true;r.settings.timerMinutes=0;r.settings.timerSeconds=1;r.settings.finalClickEnabled=true;r.settings.finalButton = .left
            let final=CGPoint(x:650,y:450);_=r.engine.captureFinalTarget(final);r.start();r.clock.advance(1.1);r.engine.confirmDelivery();let count=r.records.count;r.clock.advance(20,forceCancelled:true)
            let finals=r.downs.filter {$0.kind == "down-Left click"},regular=r.downs.filter {$0.kind == "down-Right click"}
            if r.engine.status != .stopped || finals.count != 1 || finals[0].point != final || abs(finals[0].time-1.015)>0.00001 || regular.contains(where:{$0.time>=1}) || r.records.count != count || !r.pairedWithoutDragging() { return false }
        };return true
    }
    test("Large travel clicking keeps one scheduled continuation and no catch-up after a stalled wake") {
        let r=TravelRig(speed:10);r.start();r.clock.advance(0.14);r.clock.deliverLate(by:0.5)
        let count=r.downs.count;r.clock.advance(0.01)
        if r.downs.count>count+1 {return false}
        for _ in 0..<300 {r.clock.advance(0.005);if r.clock.queued.filter({!$0.1.cancelled}).count>1 {return false}}
        return zip(r.downs,r.downs.dropFirst()).allSatisfy {$1.time-$0.time>=0.11999}
    }
}
